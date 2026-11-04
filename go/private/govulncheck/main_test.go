// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestMain doubles as govulncheck. With FAKE_GOVULNCHECK set it is a fake
// govulncheck that checks it was run with the arguments and environment the
// runner passes, and answers each of the three runs the real one is given
// from FAKE_SCAN, FAKE_TEXT (the report, after the JSON it read) and
// FAKE_SARIF, exiting with FAKE_SCAN_RC, FAKE_TEXT_RC and FAKE_SARIF_RC.
func TestMain(m *testing.M) {
	if os.Getenv("FAKE_GOVULNCHECK") != "" {
		os.Exit(fakeGovulncheck())
	}
	os.Exit(m.Run())
}

func fakeGovulncheck() int {
	// The working directory isn't checked: on Windows, rules_go's test
	// main changes it before TestMain runs. The smoke module's
	// govulncheck_test runs the real govulncheck in the module.
	if proxy := os.Getenv("GOPROXY"); proxy != "off" {
		fmt.Fprintf(os.Stderr, "fake govulncheck: GOPROXY is %q\n", proxy)
		return 4
	}
	var out, rc string
	switch args := strings.Join(os.Args[1:], " "); args {
	case "-format json ./...":
		out, rc = os.Getenv("FAKE_SCAN"), os.Getenv("FAKE_SCAN_RC")
	case "-mode=convert -format text":
		in, _ := io.ReadAll(os.Stdin)
		out, rc = os.Getenv("FAKE_TEXT")+" of "+string(in), os.Getenv("FAKE_TEXT_RC")
	case "-mode=convert -format sarif":
		out, rc = os.Getenv("FAKE_SARIF"), os.Getenv("FAKE_SARIF_RC")
	default:
		fmt.Fprintf(os.Stderr, "fake govulncheck: arguments %q\n", args)
		return 4
	}
	fmt.Print(out)
	if rc != "0" {
		fmt.Fprintln(os.Stderr, "fake govulncheck: failing")
	}
	n, _ := strconv.Atoi(rc)
	return n
}

// fake makes the binary under test a govulncheck that finds nothing.
func fake(t *testing.T) {
	t.Helper()
	t.Setenv("FAKE_GOVULNCHECK", "1")
	// The runner takes the GO* variables out of the fake's environment, and
	// among them rules_go's GO_TEST_WRAP, which says this binary is already
	// the wrapped test. With XML_OUTPUT_FILE set the fake would wrap itself
	// and print the test log, not its answer. (Setenv first, for its
	// restoring the variable afterwards.)
	t.Setenv("XML_OUTPUT_FILE", "")
	if err := os.Unsetenv("XML_OUTPUT_FILE"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_SCAN", `{"scan":1}`)
	t.Setenv("FAKE_SCAN_RC", "0")
	t.Setenv("FAKE_TEXT", "report")
	t.Setenv("FAKE_TEXT_RC", "0")
	t.Setenv("FAKE_SARIF", `{"runs":[{"results":[{"locations":[{"physicalLocation":{"artifactLocation":{"uri":"go.mod","uriBaseId":"%SRCROOT%"}}}]}]}]}`)
	t.Setenv("FAKE_SARIF_RC", "0")
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
		govulncheck: self,
		goBin:       filepath.Join("sdk", "bin", "go"),
		manifest:    manifest,
		prefix:      "mod/",
		sarif:       filepath.Join(dir, "out", "govulncheck.sarif"),
	}
}

func TestRunRendersOneScanTwice(t *testing.T) {
	fake(t)
	c := config(t)
	var out bytes.Buffer
	found, err := run(c, &out)
	if err != nil || found {
		t.Fatalf("found %v, %v", found, err)
	}
	if got, want := out.String(), `report of {"scan":1}`; got != want {
		t.Errorf("text is %q, want %q", got, want)
	}
	data, err := os.ReadFile(c.sarif)
	if err != nil || !strings.Contains(string(data), `"uri": "mod/go.mod"`) {
		t.Errorf("SARIF is %s, %v", data, err)
	}
}

func TestRunWritesNoSarifUnlessAsked(t *testing.T) {
	fake(t)
	t.Setenv("FAKE_SARIF_RC", "1") // would fail the run if it were asked for
	c := config(t)
	c.sarif = ""
	if found, err := run(c, io.Discard); err != nil || found {
		t.Fatalf("found %v, %v", found, err)
	}
}

func TestRunReportsAVulnerabilityAfterWritingTheSarif(t *testing.T) {
	fake(t)
	t.Setenv("FAKE_TEXT_RC", "3")
	c := config(t)
	var out bytes.Buffer
	found, err := run(c, &out)
	if err != nil || !found {
		t.Fatalf("found %v, %v", found, err)
	}
	if !strings.HasPrefix(out.String(), "report of ") {
		t.Errorf("text is %q", out.String())
	}
	if _, err := os.Stat(c.sarif); err != nil {
		t.Errorf("no SARIF for a failing scan: %v", err)
	}
}

func TestRunRejects(t *testing.T) {
	for name, tc := range map[string]struct {
		env, value, want string
	}{
		"failed scan":       {"FAKE_SCAN_RC", "1", "scan: exit status 1\nfake govulncheck: failing"},
		"failed SARIF":      {"FAKE_SARIF_RC", "1", "convert to SARIF: exit status 1"},
		"unreadable SARIF":  {"FAKE_SARIF", "{", "unreadable SARIF"},
		"failed text":       {"FAKE_TEXT_RC", "1", "convert to text: exit status 1"},
		"other failed text": {"FAKE_TEXT_RC", "4", "convert to text: exit status 4"},
	} {
		t.Run(name, func(t *testing.T) {
			fake(t)
			t.Setenv(tc.env, tc.value)
			_, err := run(config(t), io.Discard)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("err is %v, want it to contain %q", err, tc.want)
			}
		})
	}
}

func TestRunRejectsAMissingManifest(t *testing.T) {
	c := config(t)
	c.manifest = filepath.Join(t.TempDir(), "absent")
	if _, err := run(c, io.Discard); err == nil {
		t.Error("a missing manifest was read")
	}
}

func TestRunRejectsASarifThatCannotBeWritten(t *testing.T) {
	fake(t)
	c := config(t)
	// A file where the SARIF's directory should be.
	if err := os.WriteFile(filepath.Join(filepath.Dir(c.manifest), "out"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := run(c, io.Discard); err == nil {
		t.Error("a SARIF was written under a file")
	}
	c.sarif = filepath.Dir(c.manifest) // a directory
	if _, err := run(c, io.Discard); err == nil {
		t.Error("a SARIF was written over a directory")
	}
}

func TestMoveToRoot(t *testing.T) {
	doc := []any{
		map[string]any{"uri": "a.go", "uriBaseId": "%SRCROOT%", "x": map[string]any{"uri": "b.go", "uriBaseId": "%SRCROOT%"}},
		map[string]any{"uri": "golang.org/x/text@v0.3.6/p.go", "uriBaseId": "%GOMODCACHE%"},
		map[string]any{"uri": "no-base.go"},
		"text",
	}
	moveToRoot(doc, "mod/")
	want := `[map[uri:mod/a.go uriBaseId:%SRCROOT% x:map[uri:mod/b.go uriBaseId:%SRCROOT%]] map[uri:golang.org/x/text@v0.3.6/p.go uriBaseId:%GOMODCACHE%] map[uri:no-base.go] text]`
	if got := fmt.Sprint(doc); got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
}

func TestRunMain(t *testing.T) {
	fake(t)
	c := config(t)
	args := []string{"-govulncheck", c.govulncheck, "-go", c.goBin, "-manifest", c.manifest, "-prefix", c.prefix, "-sarif", c.sarif}
	var stdout, stderr bytes.Buffer
	if rc := runMain(args, &stdout, &stderr); rc != 0 {
		t.Fatalf("exit %d\n%s", rc, &stderr)
	}
	if stdout.Len() == 0 {
		t.Error("the report was not printed")
	}

	t.Setenv("FAKE_TEXT_RC", "3")
	stderr.Reset()
	if rc := runMain(args, io.Discard, &stderr); rc != 1 || !strings.Contains(stderr.String(), "FAIL: the code calls vulnerable functions") {
		t.Errorf("a vulnerability exits %d: %s", rc, &stderr)
	}

	t.Setenv("FAKE_SCAN_RC", "1")
	stderr.Reset()
	if rc := runMain(args, io.Discard, &stderr); rc != 1 || !strings.Contains(stderr.String(), "govulncheck: scan:") {
		t.Errorf("a failed scan exits %d: %s", rc, &stderr)
	}

	if rc := runMain(args[:4], io.Discard, io.Discard); rc != 2 {
		t.Errorf("missing flags exit %d, want 2", rc)
	}
	if rc := runMain([]string{"-nope"}, io.Discard, io.Discard); rc != 2 {
		t.Errorf("a bad flag exits %d, want 2", rc)
	}
}
