// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package scratch

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func write(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReadManifest(t *testing.T) {
	name := write(t, t.TempDir(), "manifest", "mut\tbazel-out/a.go\tp/a.go\ndep\tq.go\tq/q.go\n")
	got, err := ReadManifest(name)
	if err != nil {
		t.Fatal(err)
	}
	want := []Entry{{RoleMut, "bazel-out/a.go", "p/a.go"}, {RoleDep, "q.go", "q/q.go"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestReadManifestRejects(t *testing.T) {
	dir := t.TempDir()
	if _, err := ReadManifest(filepath.Join(dir, "missing")); err == nil {
		t.Error("a missing manifest was read")
	}
	if _, err := ReadManifest(write(t, dir, "bad", "mut\tonly-two\n")); err == nil {
		t.Error("a line of two fields was read")
	}
}

func TestNewCopiesTheModuleAndIsolatesGo(t *testing.T) {
	src := t.TempDir()
	entries := []Entry{
		{RoleMod, write(t, src, "go.mod", "module m\n"), "go.mod"},
		{RoleMut, write(t, src, "a.go", "package p\n"), "p/a.go"},
	}
	w, err := New("scratch-test-", entries, filepath.Join("sdk", "bin", "go"), "")
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(w.Mod, "p", "a.go"))
	if err != nil || string(got) != "package p\n" {
		t.Errorf("p/a.go is %q, %v", got, err)
	}
	for _, sub := range []string{"home", "tmp"} {
		if st, err := os.Stat(filepath.Join(w.Dir, sub)); err != nil || !st.IsDir() {
			t.Errorf("%s is missing: %v", sub, err)
		}
	}
	if !strings.Contains(strings.Join(w.Env, "\n"), "GOPROXY=off") {
		t.Errorf("modules are not offline: %v", w.Env)
	}
	w.Close()
	if _, err := os.Stat(w.Dir); !os.IsNotExist(err) {
		t.Errorf("Close left %s: %v", w.Dir, err)
	}
}

func TestNewRejectsAMissingSource(t *testing.T) {
	entries := []Entry{{RoleMod, filepath.Join(t.TempDir(), "absent"), "go.mod"}}
	if _, err := New("scratch-test-", entries, "go", ""); err == nil {
		t.Error("a missing source was copied")
	}
}

func TestCommandCollectsOutput(t *testing.T) {
	var out bytes.Buffer
	cmd := Command("go", []string{"version"}, t.TempDir(), os.Environ(), &out)
	if err := cmd.Run(); err != nil {
		t.Skipf("no go command to run: %v", err)
	}
	if !strings.HasPrefix(out.String(), "go version") {
		t.Errorf("output is %q", out.String())
	}
}

func TestEnviron(t *testing.T) {
	env := Environ([]string{"PATH=/usr/bin", "GOFLAGS=-mod=vendor", "CGO_ENABLED=1", "LANG=C"}, filepath.Join("sdk", "bin", "go"), "w", "")
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
	if PathOf(env) != got["PATH"] {
		t.Errorf("PathOf is %q", PathOf(env))
	}
	if FileURL("/p/proxy") != "file:///p/proxy" {
		t.Error(FileURL("/p/proxy"))
	}
	if !strings.HasPrefix(FileURL(`C:\p\proxy`), "file:///") {
		t.Error(FileURL(`C:\p\proxy`))
	}
}
