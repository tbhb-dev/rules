// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command gomutants runs the gomutants mutation tester over one unit, a Go
// package, for tbhb_rules' mutation gate.
//
// It copies the unit's module files into a scratch tree and runs gomutants
// there with the SDK's go, offline. The unit's slice of the change set
// (-changes, quality's mutation_changes_slice) sets the scope: none means a
// full run; a slice that reaches the unit's tests, data, go.mod or go.sum,
// a package it depends on or a package-level declaration, or adds, deletes
// or changes a file without changed lines, also means a full run; an empty
// slice means nothing to mutate; otherwise the run mutates only the
// functions the changed lines fall in. Then it runs gomutants twice:
// --dry-run lists every mutant, and --changed-since selects the functions
// through a fake git (this binary under the name git). Every mutant
// reported must be one the selection holds and vice versa; a mismatch is
// reported as mutant.unmapped. It writes the report mutation_gate_test
// reads, then exits 1 for an errored or interrupted count, for a diff run
// whose selected mutants are not the mutants it reported (selected other than
// total, or any mutant.unmapped line: a selected mutant with no outcome), or
// for timeouts above MUTATION_MAX_TIMEOUT_PERCENT of the mutants (set by the
// action from quality's constant, which the gate reads too). So Bazel never
// caches a run that machine load may have spoiled or that the gate rejects as
// incomplete: such a run is rerun, not replayed. Timeouts within the cap exit
// 0; the gate counts them as killed.
//
// Invoked as git, it answers the two commands gomutants' --changed-since
// runs from GOMUTANTS_FAKE_GIT_ROOT and GOMUTANTS_FAKE_GIT_DIFF.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"io/fs"
	"maps"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/tbhb-dev/rules/go/private/scratch"
)

var mainExit = os.Exit

// maxTimeoutEnv holds the most timed-out mutants, in percent of the total,
// that still count as killed. The action sets it, so it has no default.
const maxTimeoutEnv = "MUTATION_MAX_TIMEOUT_PERCENT"

func main() {
	if strings.TrimSuffix(filepath.Base(os.Args[0]), ".exe") == "git" {
		mainExit(fakeGit(os.Args[1:]))
	}
	mainExit(runMain(os.Args[1:]))
}

// span is an inclusive range of lines.
type span [2]int

// slice is the selection a unit runs with: full scope, or the function
// spans of each module-relative file in diff scope.
type slice struct {
	Scope string
	Files map[string][]span
}

var fullSlice = slice{Scope: "full"}

// changeSet is quality's change-set format, as mutation_changes_slice
// writes a unit's share: each path is one of the unit's inputs, its change
// "added", "deleted" or new-side line ranges ([] for a binary or mode-only
// change).
type changeSet struct {
	Version int                        `json:"version"`
	Files   map[string]json.RawMessage `json:"files"`
}

// makeSlice reads the unit's change set (none when the name is empty) and
// returns its selection.
func makeSlice(changes string, entries []scratch.Entry, prefix string) (slice, error) {
	if changes == "" {
		return fullSlice, nil
	}
	data, err := os.ReadFile(changes)
	if err != nil {
		return slice{}, err
	}
	var c changeSet
	if err := json.Unmarshal(data, &c); err != nil {
		return slice{}, fmt.Errorf("%s: %w", changes, err)
	}
	if c.Version != 1 || c.Files == nil {
		return slice{}, fmt.Errorf("%s: not a version 1 change set", changes)
	}
	byPath := map[string]scratch.Entry{}
	for _, e := range entries {
		byPath[prefix+e.Rel] = e
	}
	files := map[string][]span{}
	for repoPath, change := range c.Files {
		e, ok := byPath[repoPath]
		if !ok {
			return slice{}, fmt.Errorf("%s: %s is not one of the unit's files", changes, repoPath)
		}
		var ranges []span
		if err := json.Unmarshal(change, &ranges); err != nil {
			// "added" or "deleted": the file's mutants or tests are new.
			var word string
			if json.Unmarshal(change, &word) != nil || (word != "added" && word != "deleted") {
				return slice{}, fmt.Errorf("%s: %s: change %s", changes, repoPath, change)
			}
			return fullSlice, nil
		}
		if e.Role != scratch.RoleMut || len(ranges) == 0 {
			return fullSlice, nil
		}
		spans, ok, err := funcSpans(e.Src, ranges)
		if err != nil {
			return slice{}, err
		}
		if !ok {
			return fullSlice, nil
		}
		files[e.Rel] = spans
	}
	return slice{Scope: "diff", Files: files}, nil
}

// funcSpans widens each range to the whole functions (with their doc
// comments) it falls in. It reports false when a range reaches outside
// every function: a package-level declaration, an import, a comment
// between declarations.
func funcSpans(name string, ranges []span) ([]span, bool, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, name, nil, parser.ParseComments)
	if err != nil {
		return nil, false, err
	}
	var funcs []span
	for _, d := range file.Decls {
		f, ok := d.(*ast.FuncDecl)
		if !ok {
			continue
		}
		start := f.Pos()
		if f.Doc != nil {
			start = f.Doc.Pos()
		}
		funcs = append(funcs, span{fset.Position(start).Line, fset.Position(f.End()).Line})
	}
	picked := map[span]bool{}
	for _, r := range ranges {
		found := false
		for _, f := range funcs {
			if f[0] <= r[0] && r[1] <= f[1] {
				picked[f] = true
				found = true
			}
		}
		if !found {
			return nil, false, nil
		}
	}
	spans := make([]span, 0, len(picked))
	// AST declarations are already in source order. Emit each picked function once.
	for _, f := range funcs {
		if picked[f] {
			spans = append(spans, f)
		}
	}
	return spans, true, nil
}

type runConfig struct {
	gomutants string
	goBin     string
	manifest  string
	changes   string
	proxy     string
	prefix    string
	pkg       string
	report    string
	log       string
	workers   int
	flags     []string
}

// Runner filesystem operations are replaceable to exercise failures portably.
var (
	runnerAbs       = filepath.Abs
	runnerMkdir     = os.Mkdir
	runnerWriteFile = os.WriteFile
)

func runMain(args []string) int {
	var c runConfig
	fs := flag.NewFlagSet("gomutants", flag.ContinueOnError)
	fs.StringVar(&c.gomutants, "gomutants", "", "the gomutants binary")
	fs.StringVar(&c.goBin, "go", "", "the go command of the SDK to test with")
	fs.StringVar(&c.manifest, "manifest", "", "the unit's manifest")
	fs.StringVar(&c.changes, "changes", "", "the unit's change set; a full run when empty")
	fs.StringVar(&c.proxy, "proxy", "", "GOPROXY directory with the module's dependencies; none when empty")
	fs.StringVar(&c.prefix, "prefix", "", "the module directory, prefixed to the file names reported")
	fs.StringVar(&c.pkg, "pkg", "", "the unit's package directory, relative to the module")
	fs.StringVar(&c.report, "report", "", "the report to write")
	fs.StringVar(&c.log, "log", "", "where gomutants' output goes")
	fs.IntVar(&c.workers, "workers", 0, "gomutants workers; its default when 0")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	c.flags = fs.Args()
	if c.gomutants == "" || c.goBin == "" || c.manifest == "" || c.pkg == "" || c.report == "" || c.log == "" {
		fmt.Fprintln(os.Stderr, "gomutants: -gomutants, -go, -manifest, -pkg, -report and -log are required")
		return 2
	}
	maxTimeout, err := strconv.Atoi(os.Getenv(maxTimeoutEnv))
	if err != nil || maxTimeout < 0 || maxTimeout > 100 {
		fmt.Fprintf(os.Stderr, "gomutants: %s must be an integer from 0 to 100\n", maxTimeoutEnv)
		return 2
	}
	r, log, err := run(c)
	if err == nil {
		err = runnerWriteFile(c.log, log, 0o644)
	}
	if err == nil {
		err = runnerWriteFile(c.report, []byte(r.format()), 0o644)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "gomutants: %v\n", err)
		return 1
	}
	if found := r.unstable(maxTimeout); len(found) > 0 {
		fmt.Fprintf(os.Stderr, "gomutants: not cacheable: %s\n%s", strings.Join(found, ", "), log)
		if len(r.mutants) > 0 {
			sort.Strings(r.mutants)
			fmt.Fprintf(os.Stderr, "mutants not killed:\n%s\n", strings.Join(r.mutants, "\n"))
		}
		return 1
	}
	return 0
}

// result is a report in the shared format.
type result struct {
	scope                                                                    string
	total, killed, lived, notCovered, timeout, errored, skipped, interrupted int
	selected, changedUnits                                                   int
	mutants                                                                  []string
}

func (r result) format() string {
	var b strings.Builder
	fmt.Fprintf(&b, "total=%d\nkilled=%d\nlived=%d\nnot_covered=%d\n", r.total, r.killed, r.lived, r.notCovered)
	fmt.Fprintf(&b, "timeout=%d\nerrored=%d\nskipped=%d\ninterrupted=%d\n", r.timeout, r.errored, r.skipped, r.interrupted)
	fmt.Fprintf(&b, "scope=%s\n", r.scope)
	if r.scope == "diff" {
		fmt.Fprintf(&b, "selected=%d\nchanged_units=%d\n", r.selected, r.changedUnits)
	}
	mutants := append([]string(nil), r.mutants...)
	sort.Strings(mutants)
	for _, m := range mutants {
		b.WriteString(m + "\n")
	}
	return b.String()
}

// unstable names the verdicts the action must not cache: those machine load
// may have caused (errored or interrupted mutants, timeouts above maxTimeout
// percent of the total) and the incomplete diff reports the gate rejects (a
// selection that is not the total, and any unmapped mutant).
func (r result) unstable(maxTimeout int) []string {
	var found []string
	if r.errored > 0 {
		found = append(found, "errored")
	}
	if r.interrupted > 0 {
		found = append(found, "interrupted")
	}
	if r.timeout*100 > r.total*maxTimeout {
		found = append(found, fmt.Sprintf("%d timeouts of %d, above %d%%", r.timeout, r.total, maxTimeout))
	}
	if r.scope == "diff" && r.selected != r.total {
		found = append(found, fmt.Sprintf("selected %d, total %d", r.selected, r.total))
	}
	if n := r.unmapped(); n > 0 {
		found = append(found, fmt.Sprintf("%d unmapped", n))
	}
	return found
}

// unmapped counts the mutant.unmapped lines: mutants the selection and the
// report disagree on.
func (r result) unmapped() int {
	n := 0
	for _, m := range r.mutants {
		if strings.HasPrefix(m, "mutant.unmapped=") {
			n++
		}
	}
	return n
}

func run(c runConfig) (result, []byte, error) {
	var log bytes.Buffer
	entries, err := scratch.ReadManifest(c.manifest)
	if err != nil {
		return result{}, nil, err
	}
	s, err := makeSlice(c.changes, entries, c.prefix)
	if err != nil {
		return result{}, nil, err
	}
	r := result{scope: s.Scope}
	if s.Scope == "diff" && len(s.Files) == 0 {
		fmt.Fprintln(&log, "gomutants: no change reaches this package; nothing to mutate")
		return r, log.Bytes(), nil
	}

	if c.gomutants, err = runnerAbs(c.gomutants); err != nil {
		return result{}, nil, err
	}
	w, err := scratch.New("gomutants-", entries, c.goBin, c.proxy)
	if err != nil {
		return result{}, nil, err
	}
	defer w.Close()
	// The fake git answers with this exact root, and gomutants compares
	// it with the paths of the files it mutates.
	work, mod := w.Dir, w.Mod
	if err := runnerMkdir(filepath.Join(work, "bin"), 0o755); err != nil {
		return result{}, nil, err
	}
	pattern := "./" + c.pkg
	if c.pkg == "." {
		pattern = "."
	}
	common := []string{"--cache=off", "--config", filepath.Join(work, "gomutants.yml")}
	if err := runnerWriteFile(filepath.Join(work, "gomutants.yml"), nil, 0o644); err != nil {
		return result{}, nil, err
	}
	if c.workers > 0 {
		common = append(common, "--workers", strconv.Itoa(c.workers))
	}
	common = append(common, c.flags...)
	env := w.Env

	var listed []mutantKey
	if s.Scope == "diff" {
		// Every mutant of the package, to check the selection against.
		var out bytes.Buffer
		cmd := scratch.Command(c.gomutants, append(append([]string{}, common...), "--dry-run", pattern), mod, env, &out)
		fmt.Fprintf(&log, "$ gomutants %s\n", strings.Join(cmd.Args[1:], " "))
		err := cmd.Run()
		log.Write(out.Bytes())
		if err != nil {
			fmt.Fprintf(&log, "gomutants: dry run failed: %v\n", err)
			r.interrupted = 1
			return r, log.Bytes(), nil
		}
		if listed, err = parseDryRun(out.String()); err != nil {
			fmt.Fprintf(&log, "gomutants: unreadable dry run: %v\n", err)
			r.interrupted = 1
			return r, log.Bytes(), nil
		}
		inPackage(listed, c.pkg)
		if err := setUpFakeGit(work, s); err != nil {
			return result{}, nil, err
		}
		env = append(env,
			"PATH="+filepath.Join(work, "bin")+string(os.PathListSeparator)+scratch.PathOf(env),
			"GOMUTANTS_FAKE_GIT_ROOT="+mod,
			"GOMUTANTS_FAKE_GIT_DIFF="+filepath.Join(work, "changes.diff"),
		)
		common = append(common, "--changed-since", "base")
	}

	report := filepath.Join(work, "report.json")
	args := append(append(common, "--output", report), pattern)
	cmd := scratch.Command(c.gomutants, args, mod, env, &log)
	fmt.Fprintf(&log, "$ gomutants %s\n", strings.Join(args, " "))
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(&log, "gomutants: run failed: %v\n", err)
		r.interrupted = 1
		return r, log.Bytes(), nil
	}
	data, err := os.ReadFile(report)
	if errors.Is(err, fs.ErrNotExist) {
		fmt.Fprintln(&log, "gomutants: no report")
		r.interrupted = 1
		return r, log.Bytes(), nil
	}
	if err != nil {
		return result{}, nil, err
	}
	if err := r.read(data, c.prefix); err != nil {
		fmt.Fprintf(&log, "gomutants: unreadable report: %v\n", err)
		return result{scope: s.Scope, interrupted: 1}, log.Bytes(), nil
	}
	if s.Scope == "diff" {
		r.changedUnits = 1
		r.crossCheck(listed, s, data, c.prefix)
	}
	return r, log.Bytes(), nil
}

// Fake git dependencies are replaceable for portable error and platform tests.
var (
	fakeGitWriteFile            = os.WriteFile
	fakeGitExecutable           = os.Executable
	fakeGitGOOS                 = runtime.GOOS
	fakeGitOutput     io.Writer = os.Stdout
)

// setUpFakeGit writes the slice as a unified diff and puts this binary in
// work/bin as git.
func setUpFakeGit(work string, s slice) error {
	var b strings.Builder
	rels := slices.Sorted(maps.Keys(s.Files))
	for _, rel := range rels {
		fmt.Fprintf(&b, "diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n", rel, rel, rel, rel)
		for _, sp := range s.Files[rel] {
			n := sp[1] - sp[0] + 1
			fmt.Fprintf(&b, "@@ -%d,%d +%d,%d @@\n", sp[0], n, sp[0], n)
			b.WriteString(strings.Repeat("-\n", n) + strings.Repeat("+\n", n))
		}
	}
	if err := fakeGitWriteFile(filepath.Join(work, "changes.diff"), []byte(b.String()), 0o644); err != nil {
		return err
	}
	self, err := fakeGitExecutable()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(self)
	if err != nil {
		return err
	}
	name := "git"
	if fakeGitGOOS == "windows" {
		name += ".exe"
	}
	return fakeGitWriteFile(filepath.Join(work, "bin", name), data, 0o755)
}

func fakeGit(args []string) int {
	switch {
	case len(args) == 2 && args[0] == "rev-parse" && args[1] == "--show-toplevel":
		_, _ = fmt.Fprintln(fakeGitOutput, os.Getenv("GOMUTANTS_FAKE_GIT_ROOT"))
		return 0
	case len(args) > 0 && args[0] == "diff":
		data, err := os.ReadFile(os.Getenv("GOMUTANTS_FAKE_GIT_DIFF"))
		if err != nil {
			fmt.Fprintf(os.Stderr, "fake git: %v\n", err)
			return 1
		}
		_, err = fakeGitOutput.Write(data)
		if err != nil {
			return 1
		}
		return 0
	default:
		fmt.Fprintf(os.Stderr, "fake git: unexpected command: git %s\n", strings.Join(args, " "))
		return 1
	}
}

// mutantKey identifies a mutant across gomutants' dry-run listing and its
// report: module-relative file, line, column and mutator.
type mutantKey struct {
	file         string
	line, column int
	mutator      string
}

func (k mutantKey) String() string {
	return fmt.Sprintf("%s:%d:%d %s", k.file, k.line, k.column, k.mutator)
}

var (
	dryStart = regexp.MustCompile(`^\[[A-Z][A-Z ]*\] (\S+):(\d+):(\d+) `)
	dryEnd   = regexp.MustCompile(`\(([A-Z][A-Z0-9_]*)\)\s*$`)
	dryFound = regexp.MustCompile(`Discovering mutants\.\.\. (\d+) found`)
)

// maxDryRunLineBytes includes the newline, as bufio.Scanner requires.
const maxDryRunLineBytes = 16777216

// parseDryRun reads gomutants' --dry-run listing. A record starts with
// `[STATUS] file:line:col` and ends, possibly lines later when the
// original code spans lines, with `(MUTATOR)`. The number of records must
// match the count gomutants announces.
func parseDryRun(out string) ([]mutantKey, error) {
	var keys []mutantKey
	var open *mutantKey
	found := -1
	scanner := bufio.NewScanner(strings.NewReader(out))
	scanner.Buffer(nil, maxDryRunLineBytes)
	for scanner.Scan() {
		line := scanner.Text()
		if m := dryFound.FindStringSubmatch(line); m != nil {
			found, _ = strconv.Atoi(m[1])
		}
		if m := dryStart.FindStringSubmatch(line); m != nil {
			if open != nil {
				return nil, fmt.Errorf("record for %s:%d:%d never ends", open.file, open.line, open.column)
			}
			lineNo, _ := strconv.Atoi(m[2])
			col, _ := strconv.Atoi(m[3])
			open = &mutantKey{file: m[1], line: lineNo, column: col}
		}
		if open == nil {
			continue
		}
		if m := dryEnd.FindStringSubmatch(line); m != nil {
			open.mutator = m[1]
			keys = append(keys, *open)
			open = nil
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if open != nil {
		return nil, fmt.Errorf("record for %s:%d:%d never ends", open.file, open.line, open.column)
	}
	if found != len(keys) {
		return nil, fmt.Errorf("listed %d mutants, announced %d", len(keys), found)
	}
	return keys, nil
}

// inPackage makes the files of a dry-run listing of package pkg, which
// gomutants names relative to the package directory, module-relative like
// the ids in its report.
func inPackage(keys []mutantKey, pkg string) {
	for i := range keys {
		keys[i].file = path.Join(pkg, keys[i].file)
	}
}

type report struct {
	Suppressed int `json:"mutants_suppressed"`
	Files      []struct {
		Mutations []struct {
			ID          string `json:"id"`
			Type        string `json:"type"`
			Status      string `json:"status"`
			Line        int    `json:"line"`
			Column      int    `json:"column"`
			Original    string `json:"original"`
			Replacement string `json:"replacement"`
		} `json:"mutations"`
	} `json:"files"`
}

// fileOf returns the module-relative file of a mutant id, file:func:TYPE#n.
func fileOf(id string) string {
	file, _, _ := strings.Cut(id, ":")
	return file
}

// read takes the counts and the mutants not killed from gomutants' JSON.
func (r *result) read(data []byte, prefix string) error {
	var rep report
	if err := json.Unmarshal(data, &rep); err != nil {
		return err
	}
	for _, f := range rep.Files {
		for _, m := range f.Mutations {
			switch m.Status {
			case "KILLED":
				r.killed++
			case "LIVED":
				r.lived++
			case "NOT COVERED":
				r.notCovered++
			case "TIMED OUT":
				r.timeout++
			case "INFRA ERROR":
				r.errored++
			case "NOT VIABLE", "EQUIVALENT":
				r.skipped++
			default:
				return fmt.Errorf("unknown mutant status %q", m.Status)
			}
			r.total++
			if m.Status != "KILLED" {
				r.mutants = append(r.mutants, fmt.Sprintf("mutant.%s=%s%s:%d:%d %s (%s)",
					strings.ToLower(strings.ReplaceAll(m.Status, " ", "_")),
					prefix, fileOf(m.ID), m.Line, m.Column, m.Type, m.ID))
			}
		}
	}
	// Mutants a gomutants:disable directive or --exclude-calls dropped.
	r.total += rep.Suppressed
	r.skipped += rep.Suppressed
	return nil
}

// crossCheck compares the mutants gomutants reported in diff scope with
// those the dry run listed inside the slice's functions; every difference
// is a mutant.unmapped line, which fails the gate.
func (r *result) crossCheck(listed []mutantKey, s slice, data []byte, prefix string) {
	selected := map[mutantKey]int{}
	for _, k := range listed {
		if slices.ContainsFunc(s.Files[k.file], func(sp span) bool {
			return sp[0] <= k.line && k.line <= sp[1]
		}) {
			selected[k]++
			r.selected++
		}
	}
	var rep report
	_ = json.Unmarshal(data, &rep) // read already parsed it
	for _, f := range rep.Files {
		for _, m := range f.Mutations {
			k := mutantKey{fileOf(m.ID), m.Line, m.Column, m.Type}
			if selected[k] > 0 {
				selected[k]--
				continue
			}
			r.mutants = append(r.mutants, fmt.Sprintf("mutant.unmapped=%s%s (reported, not selected)", prefix, k))
		}
	}
	for k, n := range selected {
		for range n {
			r.mutants = append(r.mutants, fmt.Sprintf("mutant.unmapped=%s%s (selected, not reported)", prefix, k))
		}
	}
	r.selected += rep.Suppressed
}
