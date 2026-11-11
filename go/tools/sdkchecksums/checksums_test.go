// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package sdkchecksums

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

const (
	filename    = "go1.27.3.linux-amd64.tar.gz"
	digest      = "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"
	extension   = "@@rules_go+//go:extensions.bzl%go_sdk"
	declaration = `sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")` + "\n"
	sdks        = `{"linux_amd64": ["` + filename + `", "` + digest + `"]}`
)

func TestModule(t *testing.T) {
	for _, tc := range []struct {
		name, text, mod, wantErr string
		count                    int
	}{
		{"download", declaration + `sdk.download(version = "1.27.3", sdks = ` + sdks + `)`, "", "", 1},
		{"from_file", declaration + `sdk.from_file(go_mod = "//:go.mod", sdks = ` + sdks + `)`, "go 1.27.0\ntoolchain go1.27.3\n", "", 1},
		{"go_directive", declaration + `sdk.from_file(go_mod = "//:go.mod", sdks = ` + sdks + `)`, "go 1.27.3\n", "", 1},
		{"no_pins", declaration + `sdk.download(version = "1.27.3")`, "", "", 0},
		{"other_code", `module(name = "test")` + "\n" + `other = "value"` + "\n" + declaration + `sdk.host(version = "1.27.3")` + "\n" + `unrelated.download(sdks = dynamic)`, "", "", 0},
		{"not_sdk", `sdk = use_extension("@other//:extensions.bzl", "go_sdk")` + "\n" + `sdk.download(sdks = dynamic)`, "", "", 0},
		{"syntax", "(", "", "syntax error", 0},
		{"dynamic_dict", declaration + `sdk.download(sdks = dynamic)`, "", "literal dictionary", 0},
		{"missing_version", declaration + `sdk.download(sdks = ` + sdks + `)`, "", "SDK version", 0},
		{"missing_directive", declaration + `sdk.from_file(go_mod = "//:go.mod", sdks = ` + sdks + `)`, "module example.com/test", "SDK version", 0},
		{"work_file", declaration + `sdk.from_file(go_work = "//:go.work", sdks = ` + sdks + `)`, "", "workspace-root go_mod", 0},
		{"outside_label", declaration + `sdk.from_file(go_mod = "@other//:go.mod", sdks = ` + sdks + `)`, "", "workspace-root go_mod", 0},
		{"traversal_label", declaration + `sdk.from_file(go_mod = "//:../go.mod", sdks = ` + sdks + `)`, "", "workspace-root go_mod", 0},
		{"read_error", declaration + `sdk.from_file(go_mod = "//:go.mod", sdks = ` + sdks + `)`, "error", "read failed", 0},
		{"dynamic_pair", declaration + `sdk.download(version = "1.27.3", sdks = {"linux_amd64": value})`, "", "entries must", 0},
		{"short_pair", declaration + `sdk.download(version = "1.27.3", sdks = {"linux_amd64": ["file"]})`, "", "entries must", 0},
		{"dynamic_hash", declaration + `sdk.download(version = "1.27.3", sdks = {"linux_amd64": ["file", hash]})`, "", "entries must", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pins, err := Module([]byte(tc.text), func(name string) ([]byte, error) {
				if name != "go.mod" {
					t.Fatalf("read %s", name)
				}
				if tc.mod == "error" {
					return nil, errors.New("read failed")
				}
				return []byte(tc.mod), nil
			})
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("error = %v; want %s", err, tc.wantErr)
				}
				return
			}
			if err != nil || len(pins) != tc.count {
				t.Fatalf("pins = %v, error = %v", pins, err)
			}
			if tc.count == 1 && (pins[0].Filename != filename || pins[0].Version != "1.27.3" || pins[0].SHA256 != digest || pins[0].Platform != "linux_amd64" || pins[0].Source != "MODULE.bazel:2") {
				t.Fatalf("pin = %+v", pins[0])
			}
		})
	}
}

func lockJSON(t *testing.T, facts string, repos string) []byte {
	t.Helper()
	factData, err := json.Marshal(map[string]map[string]string{extension: {"1.27.3": facts}, "unrelated": {"ignored": "not json"}})
	if err != nil {
		t.Fatal(err)
	}
	return []byte(`{"facts": ` + string(factData) + `, "moduleExtensions": {"` + extension + `": {"general": {"generatedRepoSpecs": ` + repos + `}}, "unrelated": {}}}`)
}

func TestLock(t *testing.T) {
	repo := `{"sdk": {"repoRuleId": "@@rules_go+//go/private:sdk.bzl%go_download_sdk_rule", "attributes": {"version": "1.27.3", "sdks": ` + sdks + `}}, "ignored": {"attributes": {"sdks": {"invalid": []}}}}`
	data := lockJSON(t, sdks, repo)
	pins, err := Lock(data)
	if err != nil || len(pins) != 2 {
		t.Fatalf("pins = %v, error = %v", pins, err)
	}
	for _, pin := range pins {
		if pin.Version != "1.27.3" || pin.Platform != "linux_amd64" || pin.Filename != filename || pin.SHA256 != digest {
			t.Fatalf("pin = %+v", pin)
		}
	}
	structured := []byte(`{"facts": {"` + extension + `": {"1.27.3": ` + sdks + `}, "unrelated": {"ignored": {"key": "value"}}}}`)
	if pins, err := Lock(structured); err != nil || len(pins) != 1 || pins[0].SHA256 != digest {
		t.Fatalf("structured fact pins = %v, error = %v", pins, err)
	}
	legacy := strings.ReplaceAll(string(data), `"repoRuleId": "@@rules_go+//go/private:sdk.bzl%go_download_sdk_rule"`, `"ruleClassName": "go_download_sdk"`)
	if pins, err := Lock([]byte(legacy)); err != nil || len(pins) != 2 {
		t.Fatalf("legacy pins = %v, error = %v", pins, err)
	}
	for _, data := range [][]byte{
		[]byte("{"),
		lockJSON(t, "not json", `{}`),
		lockJSON(t, `{"linux_amd64": []}`, `{}`),
		lockJSON(t, `{}`, `{"sdk": {"ruleClassName": "go_download_sdk", "attributes": {"sdks": {"linux_amd64": []}}}}`),
	} {
		if _, err := Lock(data); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
}

func TestCompare(t *testing.T) {
	data, err := os.ReadFile("testdata/releases.json")
	if err != nil {
		t.Fatal(err)
	}
	good := Pin{"MODULE.bazel:3", "1.27.3", "linux_amd64", filename, digest}
	for _, tc := range []struct {
		name string
		pins []Pin
		data []byte
		want string
	}{
		{"match", []Pin{good}, data, ""},
		{"wrong_hash", []Pin{{"MODULE.bazel:3", "1.27.3", "linux_amd64", filename, "bad"}}, data, filename + ": sha256 mismatch: recorded bad, published " + digest},
		{"absent_version", []Pin{{"MODULE.bazel:3", "9.99.0", "linux_amd64", "go9.99.0.linux-amd64.tar.gz", digest}}, data, "9.99.0/linux_amd64 go9.99.0.linux-amd64.tar.gz: unknown published archive"},
		{"unknown_file", []Pin{{"MODULE.bazel:3", "1.27.3", "linux_amd64", "other.tar.gz", digest}}, data, "other.tar.gz: unknown published archive"},
		{"wrong_platform", []Pin{{"MODULE.bazel:3", "1.27.3", "darwin_amd64", filename, digest}}, data, "unknown published archive"},
		{"empty", nil, data, "no recorded"},
		{"bad_json", []Pin{good}, []byte("not json"), "published release list"},
		{"arm", []Pin{{"lock", "go1.27.3", "linux_arm", "go1.27.3.linux-armv6l.tar.gz", "d6f4e11dd7157030d7ac11c51c8f73201a2db932d593c3106b1da11cc32bfdf8"}}, data, ""},
		{"windows", []Pin{{"lock", "1.27.3", "windows_arm64", "go1.27.3.windows-arm64.zip", "c507872ff21f8a7cd3c1c217b059c6f7271a4a9d8e692810ef9dd3e1f601197c"}}, data, ""},
		{"installer", []Pin{good}, []byte(strings.ReplaceAll(string(data), `"archive"`, `"installer"`)), "unknown published archive"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			count, err := Compare(tc.pins, tc.data)
			if tc.want != "" {
				if err == nil || !strings.Contains(err.Error(), tc.want) {
					t.Fatalf("error = %v; want %s", err, tc.want)
				}
				return
			}
			if err != nil || count != len(tc.pins) {
				t.Fatalf("count = %d, error = %v", count, err)
			}
		})
	}
	bad := good
	bad.Source, bad.SHA256 = "z", "bad"
	bad2 := bad
	bad2.Source = "a"
	_, err = Compare([]Pin{bad, bad2}, data)
	if err == nil || !strings.HasPrefix(err.Error(), "a:") || !strings.Contains(err.Error(), "\nz:") {
		t.Fatalf("missing or unsorted diagnostics: %v", err)
	}
}
