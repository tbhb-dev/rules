// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func report(t *testing.T, json string, exit int, log string) string {
	t.Helper()
	dir := t.TempDir()
	in := filepath.Join(dir, "issues.json")
	if json != "" {
		if err := os.WriteFile(in, []byte(json), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	logFile := filepath.Join(dir, "log")
	if err := os.WriteFile(logFile, []byte(log), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "report.txt")
	if err := run(in, exit, logFile, "/ws", out); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestReport(t *testing.T) {
	for _, tc := range []struct {
		name, json string
		exit       int
		log, want  string
	}{
		{
			name: "clean",
			json: `{"Issues":null,"Report":{}}`,
			want: "",
		},
		{
			name: "issues sorted, relative to the base",
			json: `{"Issues":[
				{"FromLinter":"unused","Text":"func f is unused","Pos":{"Filename":"/ws/p/b.go","Line":3,"Column":6}},
				{"FromLinter":"errcheck","Text":"unchecked","Pos":{"Filename":"/ws/p/a.go","Line":10,"Column":2}}
			]}`,
			exit: 1,
			want: "p/a.go:10:2: unchecked (errcheck)\np/b.go:3:6: func f is unused (unused)\n",
		},
		{
			name: "findings outside the base (dependencies) dropped",
			json: `{"Issues":[
				{"FromLinter":"errcheck","Text":"unchecked","Pos":{"Filename":"/ws/p/a.go","Line":10,"Column":2}},
				{"FromLinter":"errcheck","Text":"unchecked","Pos":{"Filename":"/execroot/external/dep/d.go","Line":4,"Column":2}},
				{"FromLinter":"govet","Text":"bad","Pos":{"Filename":"/ws2/x.go","Line":1,"Column":1}}
			]}`,
			exit: 1,
			want: "p/a.go:10:2: unchecked (errcheck)\n",
		},
		{
			name: "dependency that did not type-check",
			json: `{"Issues":[
				{"FromLinter":"typecheck","Text":"undefined: rand.New","Pos":{"Filename":"/execroot/external/dep/d.go","Line":122,"Column":21}}
			]}`,
			exit: 1,
			want: "golangci-lint did not complete: a dependency did not type-check: /execroot/external/dep/d.go:122:21: undefined: rand.New\n",
		},
		{
			name: "failed run",
			json: "",
			exit: 3,
			log:  "Error: unknown linters\n",
			want: "golangci-lint did not complete: exit status 3\nError: unknown linters\n",
		},
		{
			name: "no output",
			json: "",
			exit: 0,
			want: "golangci-lint did not complete: open",
		},
		{
			name: "error in the report",
			json: `{"Issues":[],"Report":{"Error":"context loading failed"}}`,
			exit: 1,
			want: "golangci-lint did not complete: context loading failed\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := report(t, tc.json, tc.exit, tc.log)
			if tc.name == "no output" {
				if len(got) < len(tc.want) || got[:len(tc.want)] != tc.want {
					t.Errorf("report = %q, want prefix %q", got, tc.want)
				}
				return
			}
			if got != tc.want {
				t.Errorf("report = %q, want %q", got, tc.want)
			}
		})
	}
}
