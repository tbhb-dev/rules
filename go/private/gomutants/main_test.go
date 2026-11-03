// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestMain doubles as gomutants and as the fake git. Invoked as git (the
// runner copies this binary in), it is the fake git. With
// FAKE_GOMUTANTS_RC set, it is a fake gomutants: --dry-run prints
// FAKE_GOMUTANTS_DRY; otherwise it writes FAKE_GOMUTANTS_JSON to --output
// and exits with FAKE_GOMUTANTS_RC. With --changed-since it first checks
// that the fake git answers with the slice's diff, and fails (exit 3)
// otherwise.
func TestMain(m *testing.M) {
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

func unit(t *testing.T) (string, []entry) {
	t.Helper()
	dir := t.TempDir()
	return dir, []entry{
		{roleMut, write(t, dir, "src/p/p.go", pkgSource), "p/p.go"},
		{roleTest, write(t, dir, "src/p/p_test.go", "package p\n"), "p/p_test.go"},
		{roleDep, write(t, dir, "src/q/q.go", "package q\n"), "q/q.go"},
		{roleData, write(t, dir, "src/p/testdata/x", "x"), "p/testdata/x"},
		{roleMod, write(t, dir, "src/go.mod", "module m\n"), "go.mod"},
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
		"another version":   `{"version":2,"files":{}}`,
		"no files":          `{"version":1}`,
		"not JSON":          `{`,
		"another file":      `{"version":1,"files":{"mod/r/r.go":[[1,1]]}}`,
		"an unknown change": `{"version":1,"files":{"mod/p/p.go":"renamed"}}`,
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
	manifest := write(t, dir, "manifest", roleMut+"\t"+src+"\tp/p.go\n")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_GOMUTANTS_RC", rc)
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

func TestFakeGitRejectsOtherCommands(t *testing.T) {
	if fakeGit([]string{"log"}) == 0 {
		t.Error("git log answered")
	}
}

func TestEnviron(t *testing.T) {
	env := environ([]string{"PATH=/usr/bin", "GOFLAGS=-mod=vendor", "CGO_ENABLED=1", "LANG=C"}, filepath.Join("sdk", "bin", "go"), "w", "")
	got := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		if _, dup := got[k]; dup {
			t.Errorf("%s set twice", k)
		}
		got[k] = v
	}
	for k, want := range map[string]string{
		"PATH":        filepath.Join("sdk", "bin") + string(os.PathListSeparator) + "/usr/bin",
		"GOROOT":      "sdk",
		"GOFLAGS":     "-modcacherw",
		"GOPROXY":     "off",
		"CGO_ENABLED": "0",
		"LANG":        "C",
	} {
		if got[k] != want {
			t.Errorf("%s=%q, want %q", k, got[k], want)
		}
	}
	if fileURL("/p/proxy") != "file:///p/proxy" {
		t.Error(fileURL("/p/proxy"))
	}
}
