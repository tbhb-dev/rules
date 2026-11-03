// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Command driver is a static GOPACKAGESDRIVER: it answers go/packages queries
// from package metadata that Bazel computed ahead of time, so tools such as
// golangci-lint and deadcode can load packages inside a sandboxed action
// without the go command, a module cache, the network or a Bazel server.
//
// The metadata is the *.pkg.json that rules_go's go_pkg_info_aspect writes
// for every go_library and go_test, plus the standard library's list. The
// rule that runs the tool writes a JSON config (see config) and points
// GOPACKAGESDRIVER_CONFIG at it. Query patterns are ignored: the roots come
// from the config, because resolving patterns needs Bazel itself.
//
// Every package keeps its source files and gets its export data (the
// compiler's .x, or the precompiled standard library's .a). go/packages
// type-checks dependencies from export data unless asked for their syntax;
// golangci-lint reads both, since it computes analysis facts for
// dependencies from source when its cache holds none, and deadcode builds
// SSA for the whole program from source.
//
// When GOPACKAGESDRIVER_MIRROR names a directory, a workspace source file
// that also exists under it is reported at that path instead. The
// golangci-lint action copies the linted package's own files there, so that
// no path golangci-lint sees runs through a symlink (see golangci_lint.sh).
//
// Derived from the read half of rules_go's go/tools/gopackagesdriver
// (Apache-2.0, The Bazel Authors) and the static driver in
// aspect-build/rules_lint PR #901, rewritten without golang.org/x/tools.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"go/build"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// config is read from the file GOPACKAGESDRIVER_CONFIG names: one
// `key=value` per line, repeatable keys once per value. Paths are relative
// to the execution root: GOPACKAGESDRIVER_ROOT, or the working directory.
type config struct {
	// PkgJSON lists the *.pkg.json files (key pkg_json): the roots', their
	// dependencies' and the standard library's.
	PkgJSON []string
	// Roots are the package IDs (Bazel labels) to answer with (key root).
	Roots []string
	// TestMain adds the generated main package of each root that is a
	// go_test (key test_main=1), for whole-program tools like deadcode.
	TestMain bool
	// StdlibPkgDir holds the precompiled standard library as
	// <goos>_<goarch>/<importpath>.a, the export data of each package.
	StdlibPkgDir string
	GOOS         string
	GOARCH       string
	Tags         []string
	CgoEnabled   bool
	// GoVersion is the SDK's minor version (27 for go1.27.3); go/packages
	// type-checks with it, since a driver response has no module data.
	GoVersion int
}

// flatPackage is both the rules_go *.pkg.json form and go/packages' JSON
// form of a package: imports map an import path to a package ID.
type flatPackage struct {
	ID              string
	Name            string            `json:",omitempty"`
	PkgPath         string            `json:",omitempty"`
	Errors          []packageError    `json:",omitempty"`
	GoFiles         []string          `json:",omitempty"`
	CompiledGoFiles []string          `json:",omitempty"`
	OtherFiles      []string          `json:",omitempty"`
	ExportFile      string            `json:",omitempty"`
	Imports         map[string]string `json:",omitempty"`
	Standard        bool              `json:",omitempty"`
}

type packageError struct {
	Pos  string
	Msg  string
	Kind int
}

// driverResponse is go/packages' DriverResponse.
type driverResponse struct {
	NotHandled bool
	Compiler   string
	Arch       string
	Roots      []string `json:",omitempty"`
	Packages   []*flatPackage
	GoVersion  int
}

func main() {
	// go/packages falls back to `go list` only on a NotHandled response;
	// a failing driver fails the load with its stderr in the error.
	if err := run(os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "gopackagesdriver: %v\n", err)
		os.Exit(1)
	}
}

func run(out io.Writer) error {
	// The request (mode, overlays) does not change the answer: overlays
	// are for editors, and the package graph is fixed by the build.
	if _, err := io.Copy(io.Discard, os.Stdin); err != nil {
		return fmt.Errorf("reading request: %w", err)
	}
	path := os.Getenv("GOPACKAGESDRIVER_CONFIG")
	if path == "" {
		return errors.New("GOPACKAGESDRIVER_CONFIG is not set")
	}
	cfg, err := readConfig(path)
	if err != nil {
		return err
	}
	root := os.Getenv("GOPACKAGESDRIVER_ROOT")
	if root == "" {
		if root, err = os.Getwd(); err != nil {
			return err
		}
	}
	resp, err := respond(cfg, root, os.Getenv("GOPACKAGESDRIVER_MIRROR"))
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(resp)
}

func readConfig(path string) (*config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &config{}
	for n, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("%s:%d: not a key=value line", path, n+1)
		}
		switch key {
		case "pkg_json":
			cfg.PkgJSON = append(cfg.PkgJSON, value)
		case "root":
			cfg.Roots = append(cfg.Roots, value)
		case "tag":
			cfg.Tags = append(cfg.Tags, value)
		case "stdlib_pkg_dir":
			cfg.StdlibPkgDir = value
		case "goos":
			cfg.GOOS = value
		case "goarch":
			cfg.GOARCH = value
		case "cgo_enabled":
			cfg.CgoEnabled = value == "1"
		case "test_main":
			cfg.TestMain = value == "1"
		case "go_version":
			// go1.27.3, 1.27.3 or 1.27: the minor version.
			parts := strings.Split(strings.TrimPrefix(value, "go"), ".")
			if len(parts) < 2 {
				return nil, fmt.Errorf("%s:%d: go_version %q is not 1.N[.P]", path, n+1, value)
			}
			if cfg.GoVersion, err = strconv.Atoi(parts[1]); err != nil {
				return nil, fmt.Errorf("%s:%d: go_version %q: %w", path, n+1, value, err)
			}
		default:
			return nil, fmt.Errorf("%s:%d: unknown key %q", path, n+1, key)
		}
	}
	if len(cfg.Roots) == 0 {
		return nil, fmt.Errorf("%s: no root", path)
	}
	return cfg, nil
}

// respond builds the package graph reachable from the roots.
func respond(cfg *config, root, mirror string) (*driverResponse, error) {
	pkgs := map[string]*flatPackage{}
	stdlib := map[string]*flatPackage{}
	for _, f := range cfg.PkgJSON {
		if err := readPackages(filepath.Join(root, f), func(p *flatPackage) {
			// A go_test's generated main package has the test's label as
			// its ID, like the package under test does.
			if p.PkgPath == "testmain" {
				p.ID += testMainSuffix
			}
			// A package can appear in more than one file (a go_test's
			// archive and its dependency); the copies are identical.
			pkgs[p.ID] = p
			if p.Standard {
				stdlib[p.PkgPath] = p
			}
		}); err != nil {
			return nil, err
		}
	}

	bctx := build.Default
	bctx.GOOS, bctx.GOARCH = cfg.GOOS, cfg.GOARCH
	bctx.BuildTags = cfg.Tags
	bctx.CgoEnabled = cfg.CgoEnabled

	for _, id := range sortedKeys(pkgs) {
		p := pkgs[id]
		resolvePaths(p, root, mirror)
		if p.Standard {
			if p.ExportFile == "" && cfg.StdlibPkgDir != "" {
				p.ExportFile = filepath.Join(root, cfg.StdlibPkgDir, cfg.GOOS+"_"+cfg.GOARCH, p.PkgPath+".a")
			}
			// rules_go lists the standard library with `go list -compiled`
			// only when cgo is on (go/tools/builders/stdliblist.go,
			// stdliblist). With cgo off (pure, or static on some
			// platforms) CompiledGoFiles is absent, and go/packages would
			// typecheck an empty package; then GoFiles are what the
			// compiler compiled.
			if len(p.CompiledGoFiles) == 0 {
				p.CompiledGoFiles = p.GoFiles
			}
			continue
		}
		// rules_go lists every source of a target; the compiler skips the
		// ones whose build constraints do not match, and so must the driver.
		p.GoFiles = matchFiles(&bctx, p.GoFiles)
		p.CompiledGoFiles = p.GoFiles
		if p.Imports == nil {
			p.Imports = map[string]string{}
		}
		// Standard library imports are not in the archive's direct
		// dependencies, so they come from the sources' import clauses.
		if err := addImports(p, stdlib); err != nil {
			return nil, err
		}
	}

	// A go_test's sources hold the external test package (package x_test)
	// too; it gets a package of its own, as `go list -test` gives it, and
	// imports of it (from the test main) point to it.
	for _, id := range sortedKeys(pkgs) {
		if x := splitXTest(pkgs[id]); x != nil {
			pkgs[x.ID] = x
		}
	}
	for _, p := range pkgs {
		for path, id := range p.Imports {
			if x, ok := pkgs[id+xtestSuffix]; ok && x.PkgPath == path {
				p.Imports[path] = x.ID
			}
		}
	}

	var roots []string
	for _, r := range cfg.Roots {
		if _, ok := pkgs[r]; !ok {
			return nil, fmt.Errorf("root %s is not among the packages", r)
		}
		roots = append(roots, r)
		if _, ok := pkgs[r+xtestSuffix]; ok {
			roots = append(roots, r+xtestSuffix)
		}
		if _, ok := pkgs[r+testMainSuffix]; ok && cfg.TestMain {
			roots = append(roots, r+testMainSuffix)
		}
	}
	seen := map[string]bool{}
	var out []*flatPackage
	var walk func(id string)
	walk = func(id string) {
		if seen[id] {
			return
		}
		seen[id] = true
		p, ok := pkgs[id]
		if !ok {
			return
		}
		out = append(out, p)
		for _, imp := range sortedKeys(p.Imports) {
			walk(p.Imports[imp])
		}
	}
	for _, r := range roots {
		walk(r)
	}
	// Imports of packages outside the graph would make go/packages fail;
	// drop them so the import error surfaces as a type error instead.
	for _, p := range out {
		for path, id := range p.Imports {
			if _, ok := pkgs[id]; !ok {
				delete(p.Imports, path)
			}
		}
	}
	return &driverResponse{
		Compiler:  "gc",
		Arch:      cfg.GOARCH,
		Roots:     roots,
		Packages:  out,
		GoVersion: cfg.GoVersion,
	}, nil
}

// readPackages decodes a stream of packages: one per go_library, or the
// whole standard library in one file.
func readPackages(path string, onPkg func(*flatPackage)) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	for dec.More() {
		p := &flatPackage{}
		if err := dec.Decode(p); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		onPkg(p)
	}
	return nil
}

const (
	workspacePlaceholder = "__BAZEL_WORKSPACE__"
	xtestSuffix          = "_xtest"
	testMainSuffix       = "~testmain"
)

var placeholders = []string{"__BAZEL_EXECROOT__", workspacePlaceholder, "__BAZEL_OUTPUT_BASE__"}

// resolvePaths makes rules_go's placeholder paths absolute. Inside an action
// the execution root holds the workspace's sources, external repositories
// (external/...) and outputs (bazel-out/...), so all three placeholders
// are the working directory. Workspace sources copied to the mirror resolve
// to the copy.
func resolvePaths(p *flatPackage, root, mirror string) {
	resolve := func(path string) string {
		if rel, ok := strings.CutPrefix(path, workspacePlaceholder); ok && mirror != "" {
			if _, err := os.Stat(mirror + rel); err == nil {
				return mirror + rel
			}
		}
		for _, ph := range placeholders {
			if rel, ok := strings.CutPrefix(path, ph); ok {
				return root + rel
			}
		}
		return path
	}
	for _, files := range [][]string{p.GoFiles, p.CompiledGoFiles, p.OtherFiles} {
		for i := range files {
			files[i] = resolve(files[i])
		}
	}
	p.ExportFile = resolve(p.ExportFile)
}

func matchFiles(bctx *build.Context, files []string) []string {
	var out []string
	for _, f := range files {
		if ok, err := bctx.MatchFile(filepath.Dir(f), filepath.Base(f)); err == nil && ok {
			out = append(out, f)
		}
	}
	return out
}

// addImports sets the package name and resolves standard library imports.
func addImports(p *flatPackage, stdlib map[string]*flatPackage) error {
	fset := token.NewFileSet()
	for _, file := range p.GoFiles {
		f, err := parser.ParseFile(fset, file, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		if p.Name == "" && !strings.HasSuffix(f.Name.Name, "_test") {
			p.Name = f.Name.Name
		}
		for _, spec := range f.Imports {
			path, err := strconv.Unquote(spec.Path.Value)
			if err != nil || path == "C" {
				continue
			}
			if _, ok := p.Imports[path]; ok {
				continue
			}
			if s, ok := stdlib[path]; ok {
				p.Imports[path] = s.ID
			}
		}
	}
	return nil
}

// splitXTest moves a package's external test files (package <name>_test)
// into a package of their own, which imports the package under test.
func splitXTest(p *flatPackage) *flatPackage {
	if p.Standard || p.Name == "" {
		return nil
	}
	var own, xtest []string
	fset := token.NewFileSet()
	for _, file := range p.GoFiles {
		if strings.HasSuffix(file, "_test.go") {
			f, err := parser.ParseFile(fset, file, nil, parser.PackageClauseOnly)
			if err == nil && f.Name.Name == p.Name+"_test" {
				xtest = append(xtest, file)
				continue
			}
		}
		own = append(own, file)
	}
	if len(xtest) == 0 {
		return nil
	}
	p.GoFiles, p.CompiledGoFiles = own, own
	imports := map[string]string{p.PkgPath: p.ID}
	for path, id := range p.Imports {
		imports[path] = id
	}
	return &flatPackage{
		ID:              p.ID + xtestSuffix,
		Name:            p.Name + "_test",
		PkgPath:         p.PkgPath + "_test",
		GoFiles:         xtest,
		CompiledGoFiles: xtest,
		Imports:         imports,
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
