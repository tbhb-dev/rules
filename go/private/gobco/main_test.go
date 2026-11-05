// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/tbhb-dev/rules/go/private/scratch"
)

// TestMain doubles as gobco. With FAKE_GOBCO_RC set it is a fake gobco: it
// checks that it was run with the arguments and environment the runner passes,
// and, with FAKE_GOBCO_FILES set, that those are the files (comma-separated)
// of the scratch copy of the package, writes FAKE_GOBCO_STATS to the file
// -stats names (when set) and exits with FAKE_GOBCO_RC.
func TestMain(m *testing.M) {
	if rc, ok := os.LookupEnv("FAKE_GOBCO_RC"); ok {
		os.Exit(fakeGobco(rc))
	}
	os.Exit(m.Run())
}

func fakeGobco(rc string) int {
	args := os.Args[1:]
	if len(args) != 3 || args[0] != "-stats" || args[2] != filepath.Join("p", "q") {
		fmt.Fprintf(os.Stderr, "fake gobco: arguments %q\n", args)
		return 3
	}
	// The working directory isn't checked: on Windows, rules_go's test
	// main changes it before TestMain runs. The smoke module's gobco_test
	// runs the real gobco in the module.
	if proxy := os.Getenv("GOPROXY"); proxy != "off" {
		fmt.Fprintf(os.Stderr, "fake gobco: GOPROXY is %q\n", proxy)
		return 3
	}
	if want, ok := os.LookupEnv("FAKE_GOBCO_FILES"); ok {
		// The statistics file is in the scratch directory, next to mod.
		pkg := filepath.Join(filepath.Dir(args[1]), "mod", "p", "q")
		entries, err := os.ReadDir(pkg)
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		if got := strings.Join(names, ","); err != nil || got != want {
			fmt.Fprintf(os.Stderr, "fake gobco: the package has %q (%v), want %q\n", got, err, want)
			return 3
		}
	}
	if js, ok := os.LookupEnv("FAKE_GOBCO_STATS"); ok {
		if err := os.WriteFile(args[1], []byte(js), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "fake gobco: %v\n", err)
			return 3
		}
	}
	if rc == "0" {
		return 0
	}
	return 1
}

func TestRead(t *testing.T) {
	got := read([]condition{
		{"p/a.go:3:5", "x > 1", 4, 2},
		{"p/a.go:9:5", "y", 1, 0},
		{"p/b.go:2:2", `s == "a"`, 0, 7},
		{"p/b.go:8:4", "z", 0, 0},
		{"p/c.go:1:1", "w", 0, 1},
	}, "go/")
	want := result{
		covered: 2 + 1 + 1 + 0 + 1,
		total:   10,
		uncovered: []string{
			`go/p/a.go:9:5: condition "y" was once true but never false`,
			`go/p/b.go:2:2: condition "s == \"a\"" was 7 times false but never true`,
			`go/p/b.go:8:4: condition "z" was never evaluated`,
			`go/p/c.go:1:1: condition "w" was once false but never true`,
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestDescribe(t *testing.T) {
	for _, tc := range []struct {
		c    condition
		want string
	}{
		{condition{TrueCount: 3}, "was 3 times true but never false"},
		{condition{FalseCount: 1}, "was once false but never true"},
		{condition{}, "was never evaluated"},
	} {
		if got := describe(tc.c); got != tc.want {
			t.Errorf("%+v: %q, want %q", tc.c, got, tc.want)
		}
	}
}

func TestFormat(t *testing.T) {
	got := result{covered: 3, total: 4, uncovered: []string{"a.go:1:1: condition \"x\" was never evaluated"}}.format()
	want := "covered=3\ntotal=4\nuncovered=a.go:1:1: condition \"x\" was never evaluated\n"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func config(t *testing.T) runConfig {
	t.Helper()
	dir := t.TempDir()
	goMod := filepath.Join(dir, "go.mod")
	if err := os.WriteFile(goMod, []byte("module m\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(dir, "manifest")
	if err := os.WriteFile(manifest, []byte("mod\t"+goMod+"\tgo.mod\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return runConfig{
		gobco:    self,
		goBin:    filepath.Join("sdk", "bin", "go"),
		manifest: manifest,
		prefix:   "mod/",
		pkg:      "p/q",
		report:   filepath.Join(dir, "report"),
	}
}

// otherGOOS is an operating system the tests are not running on.
func otherGOOS() string {
	if runtime.GOOS == "windows" {
		return "linux"
	}
	return "windows"
}

// source writes a Go file named name, holding text, to a new directory and
// returns its path.
func source(t *testing.T, name, text string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// The fixtures: a file every platform builds, and files no platform the
// tests run on builds, which would not compile if gobco saw them.
const (
	plain   = "package q\n\nfunc Positive(n int) bool { return n > 0 }\n"
	unbuilt = "package q\n\nvar _ = undefined\n"
	ignored = "//go:build ignore\n\n" + unbuilt
)

func TestBuildable(t *testing.T) {
	entry := func(role, dir, name, text string) scratch.Entry {
		return scratch.Entry{Role: role, Src: source(t, name, text), Rel: dir + "/" + name}
	}
	entries := []scratch.Entry{
		{Role: scratch.RoleMod, Src: "go.mod", Rel: "go.mod"},
		entry(scratch.RoleMut, "p/q", "q.go", plain),
		entry(scratch.RoleMut, "p/q", "ignored.go", ignored),
		entry(scratch.RoleMut, "p/q", "cgo.go", "//go:build cgo\n\n"+unbuilt),
		entry(scratch.RoleTest, "p/q", "q_"+otherGOOS()+"_test.go", unbuilt),
		entry(scratch.RoleTest, "p/q", "here_test.go", "//go:build "+runtime.GOOS+"\n\npackage q\n"),
		entry(scratch.RoleTest, "p/q", "not_here_test.go", "//go:build !"+runtime.GOOS+"\n\n"+unbuilt),
		// Another package's files go as they are: gobco's importer
		// applies their constraints itself.
		entry(scratch.RoleDep, "p/dep", "dep.go", ignored),
	}
	got, err := buildable(entries)
	if err != nil {
		t.Fatal(err)
	}
	var rels []string
	for _, e := range got {
		rels = append(rels, e.Rel)
	}
	want := []string{"go.mod", "p/q/q.go", "p/q/here_test.go", "p/dep/dep.go"}
	if !reflect.DeepEqual(rels, want) {
		t.Errorf("kept %q, want %q", rels, want)
	}
}

func TestRun(t *testing.T) {
	t.Setenv("FAKE_GOBCO_RC", "0")
	t.Setenv("FAKE_GOBCO_STATS", `[{"Start": "p/q/q.go:4:9", "Code": "n > 0", "TrueCount": 2, "FalseCount": 0}]`)
	t.Setenv("FAKE_GOBCO_FILES", "q.go")
	c := config(t)
	other := "q_" + otherGOOS() + ".go"
	manifest := "mod\t" + filepath.Join(filepath.Dir(c.manifest), "go.mod") + "\tgo.mod\n" +
		"mut\t" + source(t, "q.go", plain) + "\tp/q/q.go\n" +
		"mut\t" + source(t, other, unbuilt) + "\tp/q/" + other + "\n" +
		"test\t" + source(t, "ignored_test.go", ignored) + "\tp/q/ignored_test.go\n"
	if err := os.WriteFile(c.manifest, []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	got, out, err := run(c)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	want := result{covered: 1, total: 2, uncovered: []string{`mod/p/q/q.go:4:9: condition "n > 0" was 2 times true but never false`}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestRunRejects(t *testing.T) {
	for name, tc := range map[string]struct {
		rc, stats string
		hasStats  bool
		want      string
	}{
		"failing tests":        {"1", `[]`, true, "gobco p/q: exit status 1"},
		"nothing instrumented": {"0", "", false, "nothing to instrument in p/q"},
		"unreadable stats":     {"0", `{`, true, "unreadable statistics"},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("FAKE_GOBCO_RC", tc.rc)
			if tc.hasStats {
				t.Setenv("FAKE_GOBCO_STATS", tc.stats)
			}
			_, out, err := run(config(t))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("err is %v, want it to contain %q\n%s", err, tc.want, out)
			}
		})
	}
}

func TestRunRejectsAMissingManifest(t *testing.T) {
	c := config(t)
	c.manifest = filepath.Join(t.TempDir(), "absent")
	if _, _, err := run(c); err == nil {
		t.Error("a missing manifest was read")
	}
}

func TestRunRejectsAnUnreadableSource(t *testing.T) {
	c := config(t)
	absent := filepath.Join(t.TempDir(), "absent.go")
	if err := os.WriteFile(c.manifest, []byte("mut\t"+absent+"\tp/q/absent.go\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(c); err == nil {
		t.Error("a missing source was read")
	}
}

func TestRunMain(t *testing.T) {
	t.Setenv("FAKE_GOBCO_RC", "0")
	t.Setenv("FAKE_GOBCO_STATS", `[{"Start": "p/q/q.go:4:9", "Code": "n > 0", "TrueCount": 2, "FalseCount": 1}]`)
	c := config(t)
	args := []string{"-gobco", c.gobco, "-go", c.goBin, "-manifest", c.manifest, "-prefix", c.prefix, "-pkg", c.pkg, "-report", c.report}
	if rc := runMain(args, os.Stderr); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	data, err := os.ReadFile(c.report)
	if err != nil || string(data) != "covered=2\ntotal=2\n" {
		t.Errorf("report is %q, %v", data, err)
	}
	t.Setenv("FAKE_GOBCO_RC", "1")
	if rc := runMain(args, os.Stderr); rc != 1 {
		t.Errorf("failing tests exit %d, want 1", rc)
	}
	if rc := runMain(args[:4], os.Stderr); rc != 2 {
		t.Errorf("missing flags exit %d, want 2", rc)
	}
	if rc := runMain([]string{"-nope"}, os.Stderr); rc != 2 {
		t.Errorf("a bad flag exits %d, want 2", rc)
	}
}
