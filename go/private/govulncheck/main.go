// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command govulncheck runs govulncheck, the Go vulnerability scanner, over a
// module, for tbhb_rules' govulncheck_test.
//
// It copies the module's files into a scratch tree and scans it there in
// source mode with the SDK's go, with modules from an offline proxy. Only
// govulncheck's fetch of the vulnerability database uses the network. One
// scan is made, as JSON, and rendered twice from that: as govulncheck's text,
// which is printed, and, when asked, as SARIF for GitHub Code Scanning. The
// exit status is 1 when the code can reach a vulnerability, or the scan
// fails, and 0 otherwise.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/tbhb-dev/rules/go/private/scratch"
)

func main() {
	os.Exit(runMain(os.Args[1:], os.Stdout, os.Stderr))
}

// exitFound is the status govulncheck's text output exits with when the code
// calls a vulnerable function.
const exitFound = 3

type runConfig struct {
	govulncheck string
	goBin       string
	manifest    string
	proxy       string
	prefix      string
	sarif       string
}

func runMain(args []string, stdout, stderr io.Writer) int {
	var c runConfig
	fs := flag.NewFlagSet("govulncheck", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&c.govulncheck, "govulncheck", "", "the govulncheck binary")
	fs.StringVar(&c.goBin, "go", "", "the go command of the SDK to load packages with")
	fs.StringVar(&c.manifest, "manifest", "", "the module's manifest")
	fs.StringVar(&c.proxy, "proxy", "", "GOPROXY directory with the module's dependencies; none when empty")
	fs.StringVar(&c.prefix, "prefix", "", "the module directory, prefixed to the file names in the SARIF")
	fs.StringVar(&c.sarif, "sarif", "", "the SARIF file to write; none when empty")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if c.govulncheck == "" || c.goBin == "" || c.manifest == "" {
		_, _ = fmt.Fprintln(stderr, "govulncheck: -govulncheck, -go and -manifest are required")
		return 2
	}
	found, err := run(c, stdout)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "govulncheck: %v\n", err)
		return 1
	}
	if found {
		_, _ = fmt.Fprintln(stderr, "govulncheck: FAIL: the code calls vulnerable functions (above)")
		return 1
	}
	return 0
}

// run scans the module and prints govulncheck's text report to stdout. It
// reports whether the code calls a vulnerable function.
func run(c runConfig, stdout io.Writer) (bool, error) {
	entries, err := scratch.ReadManifest(c.manifest)
	if err != nil {
		return false, err
	}
	if c.govulncheck, err = filepath.Abs(c.govulncheck); err != nil {
		return false, err
	}
	w, err := scratch.New("govulncheck-", entries, c.goBin, c.proxy)
	if err != nil {
		return false, err
	}
	defer w.Close()

	// In JSON mode govulncheck exits 0 whatever it finds, so a status other
	// than 0 is a failed scan.
	var scan bytes.Buffer
	if err := govulncheck(c, w, nil, &scan, "-format", "json", "./..."); err != nil {
		return false, fmt.Errorf("scan: %w", err)
	}

	if c.sarif != "" {
		var sarif bytes.Buffer
		if err := govulncheck(c, w, scan.Bytes(), &sarif, "-mode=convert", "-format", "sarif"); err != nil {
			return false, fmt.Errorf("convert to SARIF: %w", err)
		}
		if err := writeSarif(c.sarif, sarif.Bytes(), c.prefix); err != nil {
			return false, err
		}
	}

	err = govulncheck(c, w, scan.Bytes(), stdout, "-mode=convert", "-format", "text")
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == exitFound {
		return true, nil
	}
	if err != nil {
		return false, fmt.Errorf("convert to text: %w", err)
	}
	return false, nil
}

// govulncheck runs the binary in the scratch module with stdin, writing its
// standard output to out. Its standard error is part of the error.
func govulncheck(c runConfig, w *scratch.Work, stdin []byte, out io.Writer, args ...string) error {
	var stderr bytes.Buffer
	cmd := scratch.Command(c.govulncheck, args, w.Mod, w.Env, &stderr)
	cmd.Stdin = bytes.NewReader(stdin)
	cmd.Stdout = out
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w\n%s", err, stderr.Bytes())
	}
	return nil
}

// writeSarif writes the SARIF report to name, with the module's files named
// from the repository root: Code Scanning reads a relative location from
// there, and govulncheck's are from the module's directory.
func writeSarif(name string, sarif []byte, prefix string) error {
	var doc any
	if err := json.Unmarshal(sarif, &doc); err != nil {
		return fmt.Errorf("unreadable SARIF: %w", err)
	}
	moveToRoot(doc, prefix)
	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return err
	}
	return os.WriteFile(name, append(out, '\n'), 0o644)
}

// srcroot is the base of the locations in the module's own directory.
const srcroot = "%SRCROOT%"

// moveToRoot prefixes every location of doc relative to the module's
// directory with prefix, the module directory's path from the repository
// root with a trailing slash.
func moveToRoot(doc any, prefix string) {
	switch v := doc.(type) {
	case map[string]any:
		if uri, ok := v["uri"].(string); ok && v["uriBaseId"] == srcroot {
			v["uri"] = prefix + uri
		}
		for _, child := range v {
			moveToRoot(child, prefix)
		}
	case []any:
		for _, child := range v {
			moveToRoot(child, prefix)
		}
	}
}
