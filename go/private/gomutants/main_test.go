// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/tbhb-dev/rules/go/private/scratch"
)

// TestMain doubles as gomutants and as the fake git. Invoked as git (the
// runner copies this binary in), it is the fake git. With
// FAKE_GOMUTANTS_RC set, it is a fake gomutants: --dry-run prints
// FAKE_GOMUTANTS_DRY; otherwise it writes FAKE_GOMUTANTS_JSON to --output
// and exits with FAKE_GOMUTANTS_RC. With --changed-since it first checks
// that the fake git answers with the slice's diff, and fails (exit 3)
// otherwise.
func TestMain(m *testing.M) {
	// scratch drops GO* variables; restore gobco's statistics for the stand-ins.
	// Each child needs its own file: gobco overwrites rather than merges counts.
	// Measurement combines these files with the parent's statistics by location.
	if stats := os.Getenv("FAKE_GOBCO_STATS"); stats != "" {
		_ = os.Setenv("GOBCO_STATS", stats+".child."+strconv.Itoa(os.Getpid()))
	}
	if strings.TrimSuffix(filepath.Base(os.Args[0]), ".exe") == "git" {
		os.Exit(fakeGit(os.Args[1:]))
	}
	if rc, ok := os.LookupEnv("FAKE_GOMUTANTS_RC"); ok {
		os.Exit(fakeGomutants(rc))
	}
	os.Exit(m.Run())
}

func fakeGomutants(rc string) int {
	args := os.Args[1:]
	has := func(flag string) bool {
		for _, a := range args {
			if a == flag {
				return true
			}
		}
		return false
	}
	if !has("--cache=off") || os.Getenv("GOPROXY") != "off" {
		return 3
	}
	if has("--dry-run") {
		if _, err := os.Stdout.WriteString(os.Getenv("FAKE_GOMUTANTS_DRY")); err != nil {
			return 3
		}
		return 0
	}
	if has("--changed-since") {
		out, err := exec.Command("git", "diff", "--merge-base", "base").Output()
		if err != nil || !strings.Contains(string(out), "@@ -5,4 +5,4 @@") {
			return 3
		}
		root, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
		if wd, _ := os.Getwd(); err != nil || strings.TrimSpace(string(root)) != wd {
			return 3
		}
	}
	for i, a := range args {
		if a == "--output" && i+1 < len(args) {
			if js, ok := os.LookupEnv("FAKE_GOMUTANTS_JSON"); ok {
				if err := os.WriteFile(args[i+1], []byte(js), 0o644); err != nil {
					return 3
				}
			}
		}
	}
	if rc == "0" {
		return 0
	}
	return 1
}

func write(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

const pkgSource = `package p

import "fmt"

// Pass reports whether score passes.
func Pass(score int) bool {
	return score >= 50
}

var limit = 3

func Double(n int) int {
	return n * 2
}

func Hello() { fmt.Println("hi") }
`

func unit(t *testing.T) (string, []scratch.Entry) {
	t.Helper()
	dir := t.TempDir()
	return dir, []scratch.Entry{
		{Role: scratch.RoleMut, Src: write(t, dir, "src/p/p.go", pkgSource), Rel: "p/p.go"},
		{Role: scratch.RoleTest, Src: write(t, dir, "src/p/p_test.go", "package p\n"), Rel: "p/p_test.go"},
		{Role: scratch.RoleDep, Src: write(t, dir, "src/q/q.go", "package q\n"), Rel: "q/q.go"},
		{Role: scratch.RoleData, Src: write(t, dir, "src/p/testdata/x", "x"), Rel: "p/testdata/x"},
		{Role: scratch.RoleMod, Src: write(t, dir, "src/go.mod", "module m\n"), Rel: "go.mod"},
	}
}

func TestMakeSlice(t *testing.T) {
	dir, entries := unit(t)
	for _, tc := range []struct {
		name, changes string
		want          slice
	}{
		{"no change set", "", fullSlice},
		{"nothing changed", `{"version":1,"files":{}}`, slice{Scope: "diff", Files: map[string][]span{}}},
		{
			"a line in a function widens to the function and its doc comment",
			`{"version":1,"files":{"mod/p/p.go":[[7,7]]}}`,
			slice{Scope: "diff", Files: map[string][]span{"p/p.go": {{5, 8}}}},
		},
		{
			"two functions",
			`{"version":1,"files":{"mod/p/p.go":[[13,13],[16,16]]}}`,
			slice{Scope: "diff", Files: map[string][]span{"p/p.go": {{12, 14}, {16, 16}}}},
		},
		{"a package-level var", `{"version":1,"files":{"mod/p/p.go":[[10,10]]}}`, fullSlice},
		{"the imports", `{"version":1,"files":{"mod/p/p.go":[[3,3]]}}`, fullSlice},
		{"a range past a function's end", `{"version":1,"files":{"mod/p/p.go":[[7,10]]}}`, fullSlice},
		{"an added source", `{"version":1,"files":{"mod/p/p.go":"added"}}`, fullSlice},
		{"a deleted source", `{"version":1,"files":{"mod/p/p.go":"deleted"}}`, fullSlice},
		{"a mode-only change", `{"version":1,"files":{"mod/p/p.go":[]}}`, fullSlice},
		{"a test", `{"version":1,"files":{"mod/p/p_test.go":[[1,1]]}}`, fullSlice},
		{"a dependency", `{"version":1,"files":{"mod/q/q.go":[[1,1]]}}`, fullSlice},
		{"data", `{"version":1,"files":{"mod/p/testdata/x":[[1,1]]}}`, fullSlice},
		{"go.mod", `{"version":1,"files":{"mod/go.mod":[[1,1]]}}`, fullSlice},
	} {
		t.Run(tc.name, func(t *testing.T) {
			changes := ""
			if tc.changes != "" {
				changes = write(t, dir, "changes.json", tc.changes)
			}
			got, err := makeSlice(changes, entries, "mod/")
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("slice = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestMakeSliceRejects(t *testing.T) {
	dir, entries := unit(t)
	for name, changes := range map[string]string{
		"another version":     `{"version":2,"files":{}}`,
		"no files":            `{"version":1}`,
		"not JSON":            `{`,
		"another file":        `{"version":1,"files":{"mod/r/r.go":[[1,1]]}}`,
		"an unknown change":   `{"version":1,"files":{"mod/p/p.go":"renamed"}}`,
		"a non-string change": `{"version":1,"files":{"mod/p/p.go":42}}`,
	} {
		if _, err := makeSlice(write(t, dir, "c.json", changes), entries, "mod/"); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}

const dryRun = `gomutants v0.7.2
Discovering mutants... 4 found (1 not covered, 3 to test)
[PENDING] p/p.go:7:15  >= → >  (CONDITIONALS_BOUNDARY)
[PENDING] p/p.go:12:24  {
	return n * 2
} → {}  (BRANCH_FUNC)
[NOT COVERED] p/p.go:13:11  * → /  (ARITHMETIC_BASE)
[PENDING] p/p.go:7:15  >= → <  (CONDITIONALS_NEGATION)
`

func TestParseDryRun(t *testing.T) {
	got, err := parseDryRun(dryRun)
	if err != nil {
		t.Fatal(err)
	}
	want := []mutantKey{
		{"p/p.go", 7, 15, "CONDITIONALS_BOUNDARY"},
		{"p/p.go", 12, 24, "BRANCH_FUNC"},
		{"p/p.go", 13, 11, "ARITHMETIC_BASE"},
		{"p/p.go", 7, 15, "CONDITIONALS_NEGATION"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestInPackage(t *testing.T) {
	keys := []mutantKey{{"p.go", 1, 1, "X"}}
	inPackage(keys, "a/p")
	if keys[0].file != "a/p/p.go" {
		t.Errorf("file = %s", keys[0].file)
	}
	inPackage(keys, ".")
	if keys[0].file != "a/p/p.go" {
		t.Errorf("in the module root: file = %s", keys[0].file)
	}
}

func TestParseDryRunRejects(t *testing.T) {
	for name, out := range map[string]string{
		"a record that never ends": "Discovering mutants... 1 found\n[PENDING] p/p.go:1:1  {\n",
		"a count that differs":     "Discovering mutants... 2 found\n[PENDING] p/p.go:1:1  a → b  (X)\n",
		"no count":                 "[PENDING] p/p.go:1:1  a → b  (X)\n",
	} {
		if _, err := parseDryRun(out); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}

const reportJSON = `{"mutants_suppressed":1,"files":[{"file_name":"p.go","mutations":[
	{"id":"p/p.go:Pass:CONDITIONALS_BOUNDARY#1","type":"CONDITIONALS_BOUNDARY","status":"LIVED","line":7,"column":15},
	{"id":"p/p.go:Pass:CONDITIONALS_NEGATION#1","type":"CONDITIONALS_NEGATION","status":"KILLED","line":7,"column":15},
	{"id":"p/p.go:Double:ARITHMETIC_BASE#1","type":"ARITHMETIC_BASE","status":"NOT VIABLE","line":13,"column":11},
	{"id":"p/p.go:Double:RETURN_ZERO#1","type":"RETURN_ZERO","status":"NOT COVERED","line":13,"column":9},
	{"id":"p/p.go:Double:X#1","type":"X","status":"TIMED OUT","line":13,"column":9},
	{"id":"p/p.go:Double:Y#1","type":"Y","status":"INFRA ERROR","line":13,"column":9},
	{"id":"p/p.go:Double:Z#1","type":"Z","status":"EQUIVALENT","line":13,"column":9}
]}]}`

func TestRead(t *testing.T) {
	r := result{scope: "full"}
	if err := r.read([]byte(reportJSON), "mod/"); err != nil {
		t.Fatal(err)
	}
	want := `total=8
killed=1
lived=1
not_covered=1
timeout=1
errored=1
skipped=3
interrupted=0
scope=full
mutant.equivalent=mod/p/p.go:13:9 Z (p/p.go:Double:Z#1)
mutant.infra_error=mod/p/p.go:13:9 Y (p/p.go:Double:Y#1)
mutant.lived=mod/p/p.go:7:15 CONDITIONALS_BOUNDARY (p/p.go:Pass:CONDITIONALS_BOUNDARY#1)
mutant.not_covered=mod/p/p.go:13:9 RETURN_ZERO (p/p.go:Double:RETURN_ZERO#1)
mutant.not_viable=mod/p/p.go:13:11 ARITHMETIC_BASE (p/p.go:Double:ARITHMETIC_BASE#1)
mutant.timed_out=mod/p/p.go:13:9 X (p/p.go:Double:X#1)
`
	if got := r.format(); got != want {
		t.Errorf("report:\n%s\nwant:\n%s", got, want)
	}
	if got := strings.Join(r.unstable(), ","); got != "timeout,errored" {
		t.Errorf("unstable = %s", got)
	}
	if err := (&result{}).read([]byte(`{"files":[{"mutations":[{"status":"ODD"}]}]}`), ""); err == nil {
		t.Error("no error for an unknown status")
	}
}

func TestCrossCheck(t *testing.T) {
	listed := []mutantKey{
		{"p/p.go", 7, 15, "CONDITIONALS_BOUNDARY"},
		{"p/p.go", 7, 15, "CONDITIONALS_NEGATION"},
		{"p/p.go", 13, 11, "ARITHMETIC_BASE"},
	}
	s := slice{Scope: "diff", Files: map[string][]span{"p/p.go": {{5, 8}}}}
	matching := `{"files":[{"mutations":[
		{"id":"p/p.go:Pass:CONDITIONALS_BOUNDARY#1","type":"CONDITIONALS_BOUNDARY","status":"KILLED","line":7,"column":15},
		{"id":"p/p.go:Pass:CONDITIONALS_NEGATION#1","type":"CONDITIONALS_NEGATION","status":"KILLED","line":7,"column":15}]}]}`
	r := result{scope: "diff"}
	r.crossCheck(listed, s, []byte(matching), "")
	if r.selected != 2 || len(r.mutants) != 0 {
		t.Errorf("matching: selected %d, mutants %v", r.selected, r.mutants)
	}

	// One selected mutant missing, one unselected reported.
	off := `{"files":[{"mutations":[
		{"id":"p/p.go:Pass:CONDITIONALS_BOUNDARY#1","type":"CONDITIONALS_BOUNDARY","status":"KILLED","line":7,"column":15},
		{"id":"p/p.go:Double:ARITHMETIC_BASE#1","type":"ARITHMETIC_BASE","status":"KILLED","line":13,"column":11}]}]}`
	r = result{scope: "diff"}
	r.crossCheck(listed, s, []byte(off), "m/")
	want := []string{
		"mutant.unmapped=m/p/p.go:13:11 ARITHMETIC_BASE (reported, not selected)",
		"mutant.unmapped=m/p/p.go:7:15 CONDITIONALS_NEGATION (selected, not reported)",
	}
	if !reflect.DeepEqual(r.mutants, want) {
		t.Errorf("mutants = %v, want %v", r.mutants, want)
	}
}

// runFake runs the run mode against the fake gomutants.
// unsetenv unsets key for the rest of the test and restores it after.
func unsetenv(t *testing.T, key string) {
	t.Helper()
	old, ok := os.LookupEnv(key)
	if err := os.Unsetenv(key); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if ok {
			_ = os.Setenv(key, old)
		}
	})
}

func runFake(t *testing.T, changes, rc string, js *string) (int, string) {
	t.Helper()
	dir := t.TempDir()
	src := write(t, dir, "src/p.go", pkgSource)
	manifest := write(t, dir, "manifest", scratch.RoleMut+"\t"+src+"\tp/p.go\n")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_GOMUTANTS_RC", rc)
	t.Setenv("FAKE_GOBCO_STATS", os.Getenv("GOBCO_STATS"))
	t.Setenv("FAKE_GOMUTANTS_DRY", "Discovering mutants... 1 found\n[PENDING] p.go:7:15  >= → >  (CONDITIONALS_BOUNDARY)\n")
	if js != nil {
		t.Setenv("FAKE_GOMUTANTS_JSON", *js)
	}
	t.Setenv("GOPROXY", "https://proxy.golang.org") // the runner must not pass it on
	// The stand-in is this test binary, which rules_go wraps in a second
	// process when XML_OUTPUT_FILE is set and GO_TEST_WRAP, which the runner
	// drops with the other GO variables, is not. On Windows that wrapper
	// starts the test from the temp directory and changes into the runfiles,
	// so the stand-in would not run in the directory the runner chose.
	unsetenv(t, "XML_OUTPUT_FILE")
	report := filepath.Join(dir, "report")
	args := []string{
		"-gomutants", self,
		"-go", filepath.Join(dir, "sdk", "bin", "go"),
		"-manifest", manifest,
		"-pkg", "p",
		"-report", report,
		"-log", filepath.Join(dir, "log"),
	}
	if changes != "" {
		args = append(args, "-changes", write(t, dir, "changes.json", changes))
	}
	code := runMain(args)
	data, err := os.ReadFile(report)
	if err != nil {
		t.Fatalf("no report (exit %d): %v", code, err)
	}
	return code, string(data)
}

const oneLived = `{"files":[{"mutations":[{"id":"p/p.go:Pass:CONDITIONALS_BOUNDARY#1","type":"CONDITIONALS_BOUNDARY","status":"LIVED","line":7,"column":15}]}]}`

func TestRunFull(t *testing.T) {
	js := oneLived
	code, report := runFake(t, "", "0", &js)
	if code != 0 || !strings.Contains(report, "lived=1\n") || !strings.Contains(report, "scope=full\n") || strings.Contains(report, "selected=") {
		t.Errorf("exit %d, report:\n%s", code, report)
	}
}

func TestRunDiff(t *testing.T) {
	js := oneLived
	code, report := runFake(t, `{"version":1,"files":{"p/p.go":[[7,7]]}}`, "0", &js)
	for _, want := range []string{"total=1\n", "lived=1\n", "scope=diff\n", "selected=1\n", "changed_units=1\n"} {
		if !strings.Contains(report, want) {
			t.Errorf("report lacks %q (exit %d):\n%s", want, code, report)
		}
	}
	if strings.Contains(report, "unmapped") {
		t.Errorf("unmapped mutant:\n%s", report)
	}
}

func TestRunDiffNothingSelected(t *testing.T) {
	// FAKE_GOMUTANTS_RC=1 would interrupt the run: it must not run at all.
	code, report := runFake(t, `{"version":1,"files":{}}`, "1", nil)
	if code != 0 || !strings.HasPrefix(report, "total=0\n") || !strings.Contains(report, "selected=0\nchanged_units=0\n") {
		t.Errorf("exit %d, report:\n%s", code, report)
	}
}

func TestRunFailedIsInterruptedAndNotCached(t *testing.T) {
	code, report := runFake(t, "", "1", nil)
	if code != 1 || !strings.Contains(report, "interrupted=1\n") {
		t.Errorf("exit %d, report:\n%s", code, report)
	}
}

func TestRunNoReportIsInterrupted(t *testing.T) {
	code, report := runFake(t, "", "0", nil)
	if code != 1 || !strings.Contains(report, "interrupted=1\n") {
		t.Errorf("exit %d, report:\n%s", code, report)
	}
}

func TestRunUnstable(t *testing.T) {
	for _, tc := range []struct {
		name, rc, js, reason, mutants string
	}{
		{
			"timeout", "0", strings.Replace(oneLived, "LIVED", "TIMED OUT", 1), "timeout",
			"mutant.timed_out=p/p.go:7:15 CONDITIONALS_BOUNDARY (p/p.go:Pass:CONDITIONALS_BOUNDARY#1)\n",
		},
		{
			"errored", "0", `{"files":[{"file_name":"p.go","mutations":[
				{"id":"p/p.go:Pass:Z#1","type":"Z","status":"INFRA ERROR","line":7,"column":15},
				{"id":"p/p.go:Double:A#1","type":"A","status":"INFRA ERROR","line":13,"column":9},
				{"id":"p/p.go:Pass:K#1","type":"K","status":"KILLED","line":7,"column":15}
			]}]}`, "errored",
			"mutant.infra_error=p/p.go:13:9 A (p/p.go:Double:A#1)\n" +
				"mutant.infra_error=p/p.go:7:15 Z (p/p.go:Pass:Z#1)\n",
		},
		{"no report", "0", "", "interrupted", ""},
		{"run failed", "1", "", "interrupted", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stderr := write(t, t.TempDir(), "stderr", "")
			f, err := os.OpenFile(stderr, os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			old := os.Stderr
			os.Stderr = f
			t.Cleanup(func() {
				os.Stderr = old
				_ = f.Close()
			})
			var js *string
			if tc.js != "" {
				js = &tc.js
			}
			code, report := runFake(t, "", tc.rc, js)
			data, err := os.ReadFile(stderr)
			if err != nil {
				t.Fatal(err)
			}
			if code != 1 || !strings.HasPrefix(string(data), "gomutants: not cacheable: "+tc.reason+"\n$ gomutants ") {
				t.Errorf("exit %d, stderr:\n%s", code, data)
			}
			_, list, found := strings.Cut(string(data), "mutants not killed:\n")
			if found != (tc.mutants != "") || list != tc.mutants {
				t.Errorf("stderr:\n%s\nwant mutants:\n%s", data, tc.mutants)
			}
			_, mutants, _ := strings.Cut(report, "mutant.")
			if mutants != strings.TrimPrefix(tc.mutants, "mutant.") {
				t.Errorf("report:\n%s\nwant mutants:\n%s", report, tc.mutants)
			}
		})
	}
}

func TestFakeGitRejectsOtherCommands(t *testing.T) {
	if fakeGit([]string{"log"}) == 0 {
		t.Error("git log answered")
	}
}

func TestSpanJSON(t *testing.T) {
	data, err := json.Marshal(span{2, 3})
	if err != nil || string(data) != "[2,3]" {
		t.Fatalf("span = %s, %v", data, err)
	}
}

func TestMakeSliceErrors(t *testing.T) {
	dir, entries := unit(t)
	missing := filepath.Join(dir, "missing")
	got, err := makeSlice(missing, entries, "mod/")
	if !errors.Is(err, os.ErrNotExist) || !reflect.DeepEqual(got, slice{}) {
		t.Fatalf("missing changes: %+v, %v", got, err)
	}
	name := write(t, dir, "changes.json", "{")
	got, err = makeSlice(name, entries, "mod/")
	var syntax *json.SyntaxError
	if !errors.As(err, &syntax) || !strings.HasPrefix(err.Error(), name+": ") || !reflect.DeepEqual(got, slice{}) {
		t.Fatalf("invalid changes: %+v, %v", got, err)
	}
	entries[0].Src = missing
	got, err = makeSlice(write(t, dir, "changes.json", `{"version":1,"files":{"mod/p/p.go":[[7,7]]}}`), entries, "mod/")
	if !errors.Is(err, os.ErrNotExist) || !reflect.DeepEqual(got, slice{}) {
		t.Fatalf("missing source: %+v, %v", got, err)
	}
}

func TestFuncSpans(t *testing.T) {
	name := write(t, t.TempDir(), "p.go", pkgSource)
	for _, tc := range []struct {
		name         string
		ranges, want []span
		ok           bool
	}{
		{"doc through end", []span{{5, 8}}, []span{{5, 8}}, true},
		{"signature", []span{{6, 6}}, []span{{5, 8}}, true},
		{"closing brace", []span{{8, 8}}, []span{{5, 8}}, true},
		{"before doc", []span{{4, 5}}, nil, false},
		{"past end", []span{{8, 9}}, nil, false},
		{"ordered and unique", []span{{16, 16}, {12, 14}, {5, 8}, {7, 7}}, []span{{5, 8}, {12, 14}, {16, 16}}, true},
		{"empty", nil, []span{}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok, err := funcSpans(name, tc.ranges)
			if err != nil || ok != tc.ok || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("spans = %v, %v, %v; want %v, %v", got, ok, err, tc.want, tc.ok)
			}
		})
	}
}

func TestFuncSpansErrors(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{filepath.Join(dir, "missing.go"), write(t, dir, "bad.go", "package p\nfunc (")} {
		got, ok, err := funcSpans(name, []span{{1, 1}})
		if err == nil || ok || got != nil {
			t.Errorf("%s: spans = %v, %v, %v", name, got, ok, err)
		}
	}
}

func TestParseDryRunDiagnostics(t *testing.T) {
	for _, tc := range []struct{ out, want string }{
		{"", "listed 0 mutants, announced -1"},
		{"Discovering mutants... 2 found\n[PENDING] p.go:2:3  {\n[PENDING] q.go:4:5  x → y (X)\n", "record for p.go:2:3 never ends"},
		{"Discovering mutants... 0 found\n[PENDING] p.go:2:3  {\n", "record for p.go:2:3 never ends"},
	} {
		keys, err := parseDryRun(tc.out)
		if err == nil || err.Error() != tc.want || keys != nil {
			t.Errorf("parse = %v, %v; want %s", keys, err, tc.want)
		}
	}
	keys, err := parseDryRun("banner (X)\nDiscovering mutants... 0 found\n")
	if err != nil || len(keys) != 0 {
		t.Fatalf("empty listing = %v, %v", keys, err)
	}
}

func TestParseDryRunLineLimit(t *testing.T) {
	// Scanner's limit includes the newline. Keep this independent of the
	// production constant so both sides of the exact limit are pinned.
	for _, size := range []int{(1 << 24) - 1, 1 << 24} {
		out := "Discovering mutants... 0 found\n" + strings.Repeat("x", size) + "\n"
		keys, err := parseDryRun(out)
		if size == (1<<24)-1 {
			if err != nil || len(keys) != 0 {
				t.Errorf("line of %d bytes: %v, %v", size, keys, err)
			}
		} else if !errors.Is(err, bufio.ErrTooLong) || keys != nil {
			t.Errorf("line of %d bytes: %v, %v", size, keys, err)
		}
	}
}

func TestReadMalformed(t *testing.T) {
	var r result
	var syntax *json.SyntaxError
	if err := r.read([]byte("{"), "mod/"); !errors.As(err, &syntax) || !reflect.DeepEqual(r, result{}) {
		t.Fatalf("malformed report: %+v, %v", r, err)
	}
}

func TestFormat(t *testing.T) {
	r := result{scope: "diff", total: 45, killed: 1, lived: 2, notCovered: 3, timeout: 4, errored: 5, skipped: 6, interrupted: 7, selected: 8, changedUnits: 9, mutants: []string{"z", "a", "z"}}
	want := "total=45\nkilled=1\nlived=2\nnot_covered=3\ntimeout=4\nerrored=5\nskipped=6\ninterrupted=7\nscope=diff\nselected=8\nchanged_units=9\na\nz\nz\n"
	if got := r.format(); got != want {
		t.Errorf("format = %q, want %q", got, want)
	}
	if !reflect.DeepEqual(r.mutants, []string{"z", "a", "z"}) {
		t.Errorf("format changed the input: %v", r.mutants)
	}
}

func TestCrossCheckBoundaries(t *testing.T) {
	for _, tc := range []struct{ line, selected int }{{4, 0}, {5, 1}, {8, 1}, {9, 0}, {12, 1}, {14, 1}, {15, 0}} {
		r := result{scope: "diff"}
		k := mutantKey{"p.go", tc.line, 3, "X"}
		s := slice{Files: map[string][]span{"p.go": {{5, 8}, {12, 14}}}}
		r.crossCheck([]mutantKey{k}, s, []byte(`{}`), "mod/")
		var want []string
		if tc.selected != 0 {
			want = []string{fmt.Sprintf("mutant.unmapped=mod/p.go:%d:3 X (selected, not reported)", tc.line)}
		}
		if r.selected != tc.selected || !reflect.DeepEqual(r.mutants, want) {
			t.Errorf("line %d: selected %d, mutants %v; want %d, %v", tc.line, r.selected, r.mutants, tc.selected, want)
		}
	}
}

func TestCrossCheckMultiplicity(t *testing.T) {
	k := mutantKey{"p.go", 5, 3, "X"}
	mutation := `{"id":"p.go:F:X#1","type":"X","line":5,"column":3}`
	for _, tc := range []struct{ listed, reported, suppressed int }{
		{0, 0, 0}, {0, 2, 0}, {1, 0, 0}, {2, 0, 0}, {2, 1, 0}, {1, 2, 0}, {2, 2, 3},
	} {
		listed := make([]mutantKey, tc.listed)
		for i := range listed {
			listed[i] = k
		}
		mutations := make([]string, tc.reported)
		for i := range mutations {
			mutations[i] = mutation
		}
		data := fmt.Sprintf(`{"mutants_suppressed":%d,"files":[{"mutations":[%s]}]}`, tc.suppressed, strings.Join(mutations, ","))
		s := slice{Files: map[string][]span{"p.go": {{5, 8}, {5, 8}}}}
		r := result{selected: 4}
		r.crossCheck(listed, s, []byte(data), "mod/")
		var want []string
		for range max(tc.listed-tc.reported, 0) {
			want = append(want, "mutant.unmapped=mod/p.go:5:3 X (selected, not reported)")
		}
		for range max(tc.reported-tc.listed, 0) {
			want = append(want, "mutant.unmapped=mod/p.go:5:3 X (reported, not selected)")
		}
		if r.selected != 4+tc.listed+tc.suppressed || !reflect.DeepEqual(r.mutants, want) {
			t.Errorf("%+v: selected %d, mutants %v; want %v", tc, r.selected, r.mutants, want)
		}
	}
}
