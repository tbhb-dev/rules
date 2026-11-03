// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command report turns golangci-lint's JSON output into a findings report:
// one `path:line:col: text (linter)` line per issue, sorted, with paths
// relative to the working directory. An empty report means a clean run.
//
// A run that did not finish (an exit status other than 0 or 1, or an error
// in the JSON) is a finding too, so a broken config or a load failure fails
// the test instead of passing as "no issues".
//
// Only files under the base directory (the action's mirror of the main
// repository) are reported. A finding in a file outside it, an external
// dependency or the standard library, is dropped: it is not the
// repository's to fix. A typecheck error there is the exception: it means
// the dependency did not load, so everything that uses it was checked
// against an empty package, and the run counts as not completed.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type output struct {
	Issues []struct {
		FromLinter string
		Text       string
		Pos        struct {
			Filename string
			Line     int
			Column   int
		}
	}
	Report struct {
		Error string
	}
}

func main() {
	in := flag.String("in", "", "golangci-lint JSON output")
	exit := flag.Int("exit", 0, "golangci-lint exit status")
	log := flag.String("log", "", "golangci-lint stdout and stderr, shown when the run failed")
	base := flag.String("base", "", "directory reported paths are relative to; the working directory when empty")
	out := flag.String("out", "", "report to write")
	flag.Parse()
	if err := run(*in, *exit, *log, *base, *out); err != nil {
		fmt.Fprintf(os.Stderr, "report: %v\n", err)
		os.Exit(1)
	}
}

func run(in string, exit int, log, base, out string) error {
	if base == "" {
		var err error
		if base, err = os.Getwd(); err != nil {
			return err
		}
	}
	var lines []string
	failed := func(why string) {
		msg := fmt.Sprintf("golangci-lint did not complete: %s", why)
		if log != "" {
			if data, err := os.ReadFile(log); err == nil && len(data) > 0 {
				msg += "\n" + strings.TrimRight(string(data), "\n")
			}
		}
		lines = append(lines, msg)
	}

	var doc output
	data, err := os.ReadFile(in)
	switch {
	case exit != 0 && exit != 1:
		failed(fmt.Sprintf("exit status %d", exit))
	case err != nil:
		failed(err.Error())
	default:
		if err := json.Unmarshal(data, &doc); err != nil {
			failed(fmt.Sprintf("unreadable JSON output: %v", err))
		} else if doc.Report.Error != "" {
			failed(doc.Report.Error)
		}
	}

	for _, issue := range doc.Issues {
		path := issue.Pos.Filename
		if !filepath.IsAbs(path) {
			path = filepath.Join(base, path)
		}
		rel, err := filepath.Rel(base, path)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			if issue.FromLinter == "typecheck" {
				failed(fmt.Sprintf("a dependency did not type-check: %s:%d:%d: %s",
					path, issue.Pos.Line, issue.Pos.Column, issue.Text))
			}
			continue
		}
		lines = append(lines, fmt.Sprintf("%s:%d:%d: %s (%s)",
			filepath.ToSlash(rel), issue.Pos.Line, issue.Pos.Column, issue.Text, issue.FromLinter))
	}
	sort.Strings(lines)

	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return os.WriteFile(out, []byte(b.String()), 0o644)
}
