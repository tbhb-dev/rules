// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package sdkchecksums reads Bazel's Go SDK pins without executing Starlark.
package sdkchecksums

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/bazelbuild/buildtools/build"
)

// Pin identifies an archive and the platform and version Bazel expects.
type Pin struct {
	Source, Version, Platform, Filename, SHA256 string
}

// ReadFile reads a workspace-relative file, including go.mod for from_file.
type ReadFile func(string) ([]byte, error)

// Module reads literal sdks dictionaries on rules_go's download/from_file tags.
// Nonliteral SDK pins fail closed; unrelated MODULE code is never evaluated.
func Module(data []byte, read ReadFile) ([]Pin, error) {
	f, err := build.ParseModule("MODULE.bazel", data)
	if err != nil {
		return nil, err
	}
	aliases := map[string]bool{}
	for _, stmt := range f.Stmt {
		assign, ok := stmt.(*build.AssignExpr)
		if !ok {
			continue
		}
		call, ok := assign.RHS.(*build.CallExpr)
		if ok && build.FormatString(call.X) == "use_extension" && len(call.List) >= 2 &&
			strings.HasSuffix(literal(call.List[0]), "rules_go//go:extensions.bzl") && literal(call.List[1]) == "go_sdk" {
			aliases[build.FormatString(assign.LHS)] = true
		}
	}
	var pins []Pin
	for _, stmt := range f.Stmt {
		call, ok := stmt.(*build.CallExpr)
		if !ok {
			continue
		}
		dot, ok := call.X.(*build.DotExpr)
		if !ok || !aliases[build.FormatString(dot.X)] || (dot.Name != "download" && dot.Name != "from_file") {
			continue
		}
		attrs := map[string]build.Expr{}
		for _, arg := range call.List {
			if a, ok := arg.(*build.AssignExpr); ok {
				attrs[build.FormatString(a.LHS)] = a.RHS
			}
		}
		sdks, present := attrs["sdks"]
		if !present {
			continue // The lockfile can supply automatically discovered hashes.
		}
		dict, ok := sdks.(*build.DictExpr)
		if !ok {
			return nil, errors.New("MODULE.bazel: sdks must be a literal dictionary")
		}
		version := literal(attrs["version"])
		if dot.Name == "from_file" {
			label := literal(attrs["go_mod"])
			if !strings.HasPrefix(label, "//:") || strings.ContainsAny(strings.TrimPrefix(label, "//:"), "/\\") {
				return nil, errors.New("MODULE.bazel: from_file requires a workspace-root go_mod label")
			}
			mod, err := read(strings.TrimPrefix(label, "//:"))
			if err != nil {
				return nil, err
			}
			version = modVersion(string(mod))
		}
		if version == "" {
			return nil, errors.New("MODULE.bazel: SDK version must be explicit or present in go.mod")
		}
		for _, entry := range dict.List {
			platform := literal(entry.Key)
			pair, ok := entry.Value.(*build.ListExpr)
			if !ok || len(pair.List) != 2 || platform == "" || literal(pair.List[0]) == "" || literal(pair.List[1]) == "" {
				return nil, errors.New("MODULE.bazel: sdks entries must be platform: [filename, sha256] literals")
			}
			pos, _ := entry.Span()
			pins = append(pins, Pin{fmt.Sprintf("MODULE.bazel:%d", pos.Line), version, platform, literal(pair.List[0]), literal(pair.List[1])})
		}
	}
	return pins, nil
}

func literal(expr build.Expr) string {
	if s, ok := expr.(*build.StringExpr); ok {
		return s.Value
	}
	return ""
}

var modDirective = regexp.MustCompile(`(?m)^\s*(go|toolchain)\s+(\S+)`)

func modVersion(data string) string {
	version := ""
	for _, match := range modDirective.FindAllStringSubmatch(data, -1) {
		if match[1] == "toolchain" {
			return strings.TrimPrefix(match[2], "go")
		}
		version = match[2]
	}
	return version
}

type lockEntry struct {
	Generated map[string]struct {
		RuleClassName string `json:"ruleClassName"`
		RepoRuleID    string `json:"repoRuleId"`
		Attributes    struct {
			Version string              `json:"version"`
			SDKs    map[string][]string `json:"sdks"`
		} `json:"attributes"`
	} `json:"generatedRepoSpecs"`
}

// Lock reads both extension facts (Bazel 9) and generated repository specs.
func Lock(data []byte) ([]Pin, error) {
	var lock struct {
		Extensions map[string]map[string]lockEntry       `json:"moduleExtensions"`
		Facts      map[string]map[string]json.RawMessage `json:"facts"`
	}
	if err := json.Unmarshal(data, &lock); err != nil {
		return nil, err
	}
	var pins []Pin
	add := func(source, version string, sdks map[string][]string) error {
		for platform, pair := range sdks {
			if len(pair) != 2 {
				return fmt.Errorf("%s: %s must contain [filename, sha256]", source, platform)
			}
			pins = append(pins, Pin{source, version, platform, pair[0], pair[1]})
		}
		return nil
	}
	isSDK := func(extension string) bool {
		return strings.HasSuffix(extension, "//go:extensions.bzl%go_sdk") && strings.Contains(extension, "rules_go")
	}
	for extension, facts := range lock.Facts {
		if !isSDK(extension) {
			continue
		}
		for version, value := range facts {
			source := "MODULE.bazel.lock:facts:" + extension + ":" + version
			// Bazel stores facts as objects or JSON-encoded strings, depending
			// on the lockfile format version.
			var encoded string
			if err := json.Unmarshal(value, &encoded); err == nil {
				value = []byte(encoded)
			}
			var sdks map[string][]string
			if err := json.Unmarshal(value, &sdks); err != nil {
				return nil, fmt.Errorf("%s: %w", source, err)
			}
			if err := add(source, version, sdks); err != nil {
				return nil, err
			}
		}
	}
	for extension, entries := range lock.Extensions {
		if !isSDK(extension) {
			continue
		}
		for key, entry := range entries {
			source := "MODULE.bazel.lock:" + extension + ":" + key
			for name, repo := range entry.Generated {
				if repo.RuleClassName == "go_download_sdk" || strings.HasSuffix(repo.RepoRuleID, "%go_download_sdk_rule") {
					if err := add(source+":"+name, repo.Attributes.Version, repo.Attributes.SDKs); err != nil {
						return nil, err
					}
				}
			}
		}
	}
	return pins, nil
}

type release struct {
	Version string `json:"version"`
	Files   []struct {
		Filename string `json:"filename"`
		OS       string `json:"os"`
		Arch     string `json:"arch"`
		SHA256   string `json:"sha256"`
		Kind     string `json:"kind"`
	} `json:"files"`
}

// Compare checks every record, including duplicate pins from different sources.
// Diagnostics are sorted so map iteration cannot change failure output.
func Compare(pins []Pin, data []byte) (int, error) {
	var releases []release
	if err := json.Unmarshal(data, &releases); err != nil {
		return 0, fmt.Errorf("published release list: %w", err)
	}
	if len(pins) == 0 {
		return 0, errors.New("no recorded Go SDK archive checksums found")
	}
	index := map[string]map[string]string{}
	for _, release := range releases {
		for _, file := range release.Files {
			if file.Kind != "archive" {
				continue
			}
			arch := file.Arch
			if arch == "armv6l" {
				arch = "arm" // rules_go normalizes the Go download platform.
			}
			key := strings.TrimPrefix(release.Version, "go") + "/" + file.OS + "_" + arch
			if index[key] == nil {
				index[key] = map[string]string{}
			}
			index[key][file.Filename] = file.SHA256
		}
	}
	var failures []string
	for _, pin := range pins {
		key := strings.TrimPrefix(pin.Version, "go") + "/" + pin.Platform
		want, ok := index[key][pin.Filename]
		switch {
		case !ok:
			failures = append(failures, fmt.Sprintf("%s: %s %s: unknown published archive", pin.Source, key, pin.Filename))
		case want != pin.SHA256:
			failures = append(failures, fmt.Sprintf("%s: %s %s: sha256 mismatch: recorded %s, published %s", pin.Source, key, pin.Filename, pin.SHA256, want))
		}
	}
	if len(failures) > 0 {
		sort.Strings(failures)
		return 0, errors.New(strings.Join(failures, "\n"))
	}
	return len(pins), nil
}
