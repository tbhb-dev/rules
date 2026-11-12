// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tbhb-dev/rules/go/tools/sdkchecksums"
)

const module = `go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
go_sdk.download(version = "1.27.3", sdks = {"linux_amd64": ["go1.27.3.linux-amd64.tar.gz", "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"]})`

type transport func(*http.Request) (*http.Response, error)

func (f transport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestRun(t *testing.T) {
	data, err := os.ReadFile("sdkchecksums/testdata/releases.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, text   string
		args         []string
		status, code int
		want         string
	}{
		{"match", module, nil, 200, 0, "checked 1 archive checksums"},
		{"wrong", strings.ReplaceAll(module, "65efbc", "badbad"), nil, 200, 1, "go1.27.3.linux-amd64.tar.gz: sha256 mismatch"},
		{"missing_version", strings.ReplaceAll(module, "1.27.3", "9.99.0"), nil, 200, 1, "unknown published archive"},
		{"bad_flag", module, []string{"--unknown"}, 200, 1, "flag provided but not defined"},
		{"parse_error", "(", nil, 200, 1, "syntax error"},
		{"http_error", module, nil, 503, 1, "HTTP Service Unavailable"},
		{"transport_error", module, nil, 0, 1, "offline"},
		{"no_pins", "", nil, 200, 1, "no recorded"},
		{"unchanged", module, []string{"--changed-since=base"}, 200, 0, "unchanged; skipping network"},
		{"changed", module, []string{"--changed-since=changed"}, 200, 0, "checked 1 archive checksums"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "MODULE.bazel"), []byte(tc.text), 0o600); err != nil {
				t.Fatal(err)
			}
			client := &http.Client{Transport: transport(func(r *http.Request) (*http.Response, error) {
				if tc.name == "unchanged" {
					t.Fatal("unchanged pins must not use network")
				}
				if r.URL.String() != releaseURL {
					t.Fatalf("URL = %s", r.URL)
				}
				if tc.status == 0 {
					return nil, errors.New("offline")
				}
				return &http.Response{StatusCode: tc.status, Status: http.StatusText(tc.status), Body: io.NopCloser(bytes.NewReader(data))}, nil
			})}
			command := func(_ string, args ...string) ([]byte, error) {
				if args[0] == "diff" && args[1] == "changed" {
					return []byte("diff"), nil
				}
				return nil, nil
			}
			var out bytes.Buffer
			if code := run(tc.args, dir, &out, client, command); code != tc.code || !strings.Contains(out.String(), tc.want) {
				t.Fatalf("exit %d: %s; want exit %d, %s", code, &out, tc.code, tc.want)
			}
		})
	}
}

func TestReadPins(t *testing.T) {
	for _, tc := range []struct {
		name, lock string
		readErr    error
		want       string
	}{
		{"valid_lock", `{}`, nil, ""},
		{"bad_lock", `{`, nil, "unexpected end"},
		{"missing_module", "", fs.ErrNotExist, "does not exist"},
		{"unreadable_lock", "", fs.ErrPermission, "permission denied"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := readPins(func(name string) ([]byte, error) {
				if name == "MODULE.bazel" && tc.name != "missing_module" {
					return []byte(module), nil
				}
				return []byte(tc.lock), tc.readErr
			})
			if tc.want == "" && err != nil || tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)) {
				t.Fatalf("error = %v; want %s", err, tc.want)
			}
		})
	}
}

func TestChanged(t *testing.T) {
	pins, err := sdkchecksums.Module([]byte(module), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, baseline string
		diffErr        bool
		want           bool
	}{
		{"same", module, false, false},
		{"only_line_numbers", "\n\n" + module, false, false},
		{"different", strings.ReplaceAll(module, "65efbc", "badbad"), false, true},
		{"invalid_baseline", "(", false, true},
		{"unreadable_baseline", "error", false, true},
		{"diff_error", module, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			command := func(_ string, args ...string) ([]byte, error) {
				if args[0] == "diff" {
					if tc.diffErr {
						return nil, errors.New("git failed")
					}
					return []byte("diff"), nil
				}
				if strings.HasSuffix(args[1], "MODULE.bazel.lock") || tc.baseline == "error" {
					return nil, errors.New("absent")
				}
				return []byte(tc.baseline), nil
			}
			if got := changed(".", "base", pins, command); got != tc.want {
				t.Fatalf("changed = %v; want %v", got, tc.want)
			}
		})
	}
}

type brokenReader struct{}

func (brokenReader) Read([]byte) (int, error) { return 0, errors.New("read failed") }
func (brokenReader) Close() error             { return nil }

func TestFetchReadFailure(t *testing.T) {
	client := &http.Client{Transport: transport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: brokenReader{}}, nil
	})}
	if _, err := fetch(client); err == nil || !strings.Contains(err.Error(), "read failed") {
		t.Fatalf("error = %v", err)
	}
}

func TestGit(t *testing.T) {
	if _, err := git(t.TempDir(), "status"); err == nil {
		t.Fatal("git status succeeded outside a repository")
	}
}
