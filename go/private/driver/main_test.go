// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// write creates the file rel under dir, with its directories.
func write(t *testing.T, dir, rel, content string) {
	t.Helper()
	path := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReadConfig(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "ok", "root=//a:a\npkg_json=a.pkg.json\ntag=x\ngoos=linux\ngoarch=amd64\ngo_version=1.27.3\ncgo_enabled=1\ntest_main=1\n")
	cfg, err := readConfig(filepath.Join(dir, "ok"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.GoVersion != 27 || !cfg.CgoEnabled || !cfg.TestMain || cfg.GOOS != "linux" ||
		!slices.Equal(cfg.Roots, []string{"//a:a"}) || !slices.Equal(cfg.Tags, []string{"x"}) {
		t.Errorf("readConfig = %+v", cfg)
	}

	for name, content := range map[string]string{
		"no root":     "pkg_json=a.pkg.json\n",
		"unknown key": "root=//a:a\nflavor=mint\n",
		"not k=v":     "root=//a:a\njunk\n",
		"bad version": "root=//a:a\ngo_version=27\n",
	} {
		write(t, dir, "bad", content)
		if _, err := readConfig(filepath.Join(dir, "bad")); err == nil {
			t.Errorf("%s: readConfig accepted %q", name, content)
		}
	}
}

// fixture lays out a package a (with internal and external tests and a
// go_test whose test main shares its ID, as rules_go writes them), a
// package b importing a, and a two-package standard library.
func fixture(t *testing.T) (root string, cfg *config) {
	t.Helper()
	root = t.TempDir()
	write(t, root, "a/a.go", "package a\n\nimport \"fmt\"\n\nvar _ = fmt.Sprint\n")
	write(t, root, "a/a_linux.go", "package a\n")
	write(t, root, "a/a_test.go", "package a\n\nimport \"testing\"\n\nfunc TestA(t *testing.T) {}\n")
	write(t, root, "a/x_test.go", "package a_test\n\nimport \"testing\"\n\nfunc TestX(t *testing.T) {}\n")
	write(t, root, "b/b.go", "package b\n\nimport _ \"example.com/a\"\n")
	write(t, root, "out/a_test/testmain.go", "package main\n")
	write(t, root, "stdlib.pkg.json", `{"ID":"@std//:fmt","Name":"fmt","PkgPath":"fmt","Standard":true,"GoFiles":["__BAZEL_OUTPUT_BASE__/sdk/src/fmt/print.go"]}
{"ID":"@std//:testing","Name":"testing","PkgPath":"testing","Standard":true}
`)
	write(t, root, "a.pkg.json", `{"ID":"//a:a","PkgPath":"example.com/a","ExportFile":"__BAZEL_EXECROOT__/out/a.x","GoFiles":["__BAZEL_WORKSPACE__/a/a.go","__BAZEL_WORKSPACE__/a/a_linux.go"]}`)
	write(t, root, "a_test.pkg.json", `{"ID":"//a:a_test","PkgPath":"example.com/a","GoFiles":["__BAZEL_WORKSPACE__/a/a.go","__BAZEL_WORKSPACE__/a/a_test.go","__BAZEL_WORKSPACE__/a/x_test.go"]}`)
	write(t, root, "a_test~testmain.pkg.json", `{"ID":"//a:a_test","PkgPath":"testmain","GoFiles":["__BAZEL_EXECROOT__/out/a_test/testmain.go"],"Imports":{"example.com/a":"//a:a_test","example.com/a_test":"//a:a_test"}}`)
	write(t, root, "b.pkg.json", `{"ID":"//b:b","PkgPath":"example.com/b","GoFiles":["__BAZEL_WORKSPACE__/b/b.go"],"Imports":{"example.com/a":"//a:a"}}`)
	cfg = &config{
		PkgJSON:      []string{"stdlib.pkg.json", "a.pkg.json", "a_test.pkg.json", "a_test~testmain.pkg.json", "b.pkg.json"},
		StdlibPkgDir: "stdlib",
		GOOS:         "darwin",
		GOARCH:       "arm64",
		GoVersion:    27,
	}
	return root, cfg
}

func byID(resp *driverResponse) map[string]*flatPackage {
	m := map[string]*flatPackage{}
	for _, p := range resp.Packages {
		m[p.ID] = p
	}
	return m
}

func TestRespondLibrary(t *testing.T) {
	root, cfg := fixture(t)
	cfg.Roots = []string{"//b:b"}
	resp, err := respond(cfg, root, "")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(resp.Roots, []string{"//b:b"}) || resp.GoVersion != 27 || resp.Arch != "arm64" {
		t.Errorf("response = %+v", resp)
	}
	pkgs := byID(resp)
	a, ok := pkgs["//a:a"]
	if !ok {
		t.Fatalf("dependency //a:a missing: %v", pkgs)
	}
	// The linux-only file does not match darwin.
	if want := []string{filepath.Join(root, "a/a.go")}; !slices.Equal(a.GoFiles, want) {
		t.Errorf("a.GoFiles = %v, want %v", a.GoFiles, want)
	}
	if a.ExportFile != filepath.Join(root, "out/a.x") || a.Name != "a" {
		t.Errorf("a = %+v", a)
	}
	// The standard library import comes from the import clause.
	if a.Imports["fmt"] != "@std//:fmt" {
		t.Errorf("a.Imports = %v", a.Imports)
	}
	fmtPkg := pkgs["@std//:fmt"]
	if fmtPkg == nil || fmtPkg.ExportFile != filepath.Join(root, "stdlib/darwin_arm64/fmt.a") ||
		!slices.Equal(fmtPkg.GoFiles, []string{filepath.Join(root, "sdk/src/fmt/print.go")}) {
		t.Errorf("fmt = %+v", fmtPkg)
	}
	if _, ok := pkgs["//a:a_test"]; ok {
		t.Error("a package b does not reach is in the response")
	}
}

func TestRespondTest(t *testing.T) {
	root, cfg := fixture(t)
	cfg.Roots = []string{"//a:a_test"}
	resp, err := respond(cfg, root, "")
	if err != nil {
		t.Fatal(err)
	}
	// The external test package is a root of its own; the test main is
	// not, unless asked for.
	if want := []string{"//a:a_test", "//a:a_test_xtest"}; !slices.Equal(resp.Roots, want) {
		t.Errorf("Roots = %v, want %v", resp.Roots, want)
	}
	pkgs := byID(resp)
	internal, xtest := pkgs["//a:a_test"], pkgs["//a:a_test_xtest"]
	if internal == nil || internal.PkgPath != "example.com/a" || len(internal.GoFiles) != 2 {
		t.Errorf("internal test package = %+v", internal)
	}
	if xtest == nil || xtest.Name != "a_test" || xtest.PkgPath != "example.com/a_test" ||
		xtest.Imports["example.com/a"] != "//a:a_test" || xtest.Imports["testing"] != "@std//:testing" {
		t.Errorf("external test package = %+v", xtest)
	}

	cfg.TestMain = true
	resp, err = respond(cfg, root, "")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(resp.Roots, "//a:a_test~testmain") {
		t.Fatalf("Roots = %v, want the test main", resp.Roots)
	}
	main := byID(resp)["//a:a_test~testmain"]
	if main.Imports["example.com/a_test"] != "//a:a_test_xtest" || main.Imports["example.com/a"] != "//a:a_test" {
		t.Errorf("test main imports = %v", main.Imports)
	}
}

func TestRespondMirror(t *testing.T) {
	root, cfg := fixture(t)
	cfg.Roots = []string{"//b:b"}
	mirror := t.TempDir()
	write(t, mirror, "b/b.go", "package b\n\nimport _ \"example.com/a\"\n")
	resp, err := respond(cfg, root, mirror)
	if err != nil {
		t.Fatal(err)
	}
	pkgs := byID(resp)
	if got := pkgs["//b:b"].GoFiles; !slices.Equal(got, []string{filepath.Join(mirror, "b/b.go")}) {
		t.Errorf("mirrored b.GoFiles = %v", got)
	}
	if got := pkgs["//a:a"].GoFiles[0]; !strings.HasPrefix(got, root) {
		t.Errorf("unmirrored a.GoFiles[0] = %v, want under %v", got, root)
	}
}

func TestRespondMissingRoot(t *testing.T) {
	root, cfg := fixture(t)
	cfg.Roots = []string{"//c:c"}
	if _, err := respond(cfg, root, ""); err == nil {
		t.Error("respond accepted a root without metadata")
	}
}
