// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command gobco runs gobco, the Go condition-coverage tool, over one unit, a
// Go package, for tbhb_rules' gobco_test.
//
// It copies the unit's module files into a scratch tree and runs gobco there
// with the SDK's go, offline. It leaves out of the copy the package's own
// files that build constraints exclude on the platform it runs on, since
// gobco type-checks every file of the package whatever its constraints.
// gobco instruments the package, runs its tests
// and writes how often each condition was true and false to a JSON file;
// this command reads that and writes the report gobco_test checks:
// `covered=N`, `total=M` (two outcomes for each condition) and one
// `uncovered=<file>:<line>:<column>: condition "<code>" was ...` for each
// condition with an outcome the tests never reached. It exits 1, and writes
// no report, when the tests fail under gobco or gobco instruments nothing,
// so Bazel never caches either.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"go/build"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/tbhb-dev/rules/go/private/scratch"
)

func main() {
	os.Exit(runMain(os.Args[1:], os.Stderr))
}

type runConfig struct {
	gobco    string
	goBin    string
	manifest string
	proxy    string
	prefix   string
	pkg      string
	report   string
}

func runMain(args []string, stderr *os.File) int {
	var c runConfig
	fs := flag.NewFlagSet("gobco", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&c.gobco, "gobco", "", "the gobco binary")
	fs.StringVar(&c.goBin, "go", "", "the go command of the SDK to test with")
	fs.StringVar(&c.manifest, "manifest", "", "the unit's manifest")
	fs.StringVar(&c.proxy, "proxy", "", "GOPROXY directory with the module's dependencies; none when empty")
	fs.StringVar(&c.prefix, "prefix", "", "the module directory, prefixed to the file names reported")
	fs.StringVar(&c.pkg, "pkg", "", "the unit's package directory, relative to the module")
	fs.StringVar(&c.report, "report", "", "the report to write")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if c.gobco == "" || c.goBin == "" || c.manifest == "" || c.pkg == "" || c.report == "" {
		_, _ = fmt.Fprintln(stderr, "gobco: -gobco, -go, -manifest, -pkg and -report are required")
		return 2
	}
	r, log, err := run(c)
	if err == nil {
		err = os.WriteFile(c.report, []byte(r.format()), 0o644)
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "gobco: %v\n%s", err, log)
		return 1
	}
	return 0
}

// condition is one entry of gobco's statistics file.
type condition struct {
	Start      string
	Code       string
	TrueCount  int
	FalseCount int
}

// result is a report: the outcomes reached of those there are, and a line
// for each condition that missed one.
type result struct {
	covered, total int
	uncovered      []string
}

func (r result) format() string {
	var b strings.Builder
	fmt.Fprintf(&b, "covered=%d\ntotal=%d\n", r.covered, r.total)
	for _, u := range r.uncovered {
		b.WriteString("uncovered=" + u + "\n")
	}
	return b.String()
}

// read counts the outcomes of conds. Locations are file:line:column of the
// module-relative file, made relative to the repository with prefix.
func read(conds []condition, prefix string) result {
	var r result
	for _, c := range conds {
		r.total += 2
		if c.TrueCount > 0 {
			r.covered++
		}
		if c.FalseCount > 0 {
			r.covered++
		}
		if c.TrueCount > 0 && c.FalseCount > 0 {
			continue
		}
		r.uncovered = append(r.uncovered, fmt.Sprintf("%s%s: condition %q %s", prefix, filepath.ToSlash(c.Start), c.Code, describe(c)))
	}
	return r
}

// describe says which outcome of c was missed, in gobco's words.
func describe(c condition) string {
	switch {
	case c.TrueCount == 0 && c.FalseCount == 0:
		return "was never evaluated"
	case c.TrueCount == 0:
		return "was " + times(c.FalseCount) + " false but never true"
	default:
		return "was " + times(c.TrueCount) + " true but never false"
	}
}

func times(n int) string {
	if n == 1 {
		return "once"
	}
	return fmt.Sprintf("%d times", n)
}

// run instruments the unit's package with gobco and runs its tests. It
// returns gobco's output too, for the error.
func run(c runConfig) (result, []byte, error) {
	entries, err := scratch.ReadManifest(c.manifest)
	if err != nil {
		return result{}, nil, err
	}
	if entries, err = buildable(entries); err != nil {
		return result{}, nil, err
	}
	if c.gobco, err = filepath.Abs(c.gobco); err != nil {
		return result{}, nil, err
	}
	w, err := scratch.New("gobco-", entries, c.goBin, c.proxy)
	if err != nil {
		return result{}, nil, err
	}
	defer w.Close()

	// gobco merges into a statistics file that exists, so it names a new one.
	stats := filepath.Join(w.Dir, "gobco-stats.json")
	var out bytes.Buffer
	cmd := scratch.Command(c.gobco, []string{"-stats", stats, filepath.FromSlash(c.pkg)}, w.Mod, w.Env, &out)
	if err := cmd.Run(); err != nil {
		return result{}, out.Bytes(), fmt.Errorf("gobco %s: %w", c.pkg, err)
	}
	data, err := os.ReadFile(stats)
	if errors.Is(err, fs.ErrNotExist) {
		return result{}, out.Bytes(), fmt.Errorf("gobco found nothing to instrument in %s", c.pkg)
	}
	if err != nil {
		return result{}, out.Bytes(), err
	}
	var conds []condition
	if err := json.Unmarshal(data, &conds); err != nil {
		return result{}, out.Bytes(), fmt.Errorf("unreadable statistics: %w", err)
	}
	return read(conds, c.prefix), out.Bytes(), nil
}

// buildable drops the package's own sources and tests that build
// constraints (a //go:build line, a _GOOS or _GOARCH file name suffix)
// exclude on the platform the tests run on. gobco parses and type-checks
// every file in the package's directory, so a file for another platform
// would stop it. The packages it imports need nothing: gobco loads them
// through go/build, which honors their constraints.
func buildable(entries []scratch.Entry) ([]scratch.Entry, error) {
	// build.Default for its release tags. scratch.Environ drops the host's
	// GO* settings and turns cgo off, so the go command builds the tests for
	// the platform this runner runs on, without cgo.
	ctx := build.Default
	ctx.GOOS = runtime.GOOS
	ctx.GOARCH = runtime.GOARCH
	ctx.CgoEnabled = false
	var kept []scratch.Entry
	for _, e := range entries {
		if e.Role == scratch.RoleMut || e.Role == scratch.RoleTest {
			match, err := ctx.MatchFile(filepath.Split(e.Src))
			if err != nil {
				return nil, err
			}
			if !match {
				continue
			}
		}
		kept = append(kept, e)
	}
	return kept, nil
}
