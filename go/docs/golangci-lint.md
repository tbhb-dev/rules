# golangci-lint under Bazel: design and gaps

How `golangci_lint_aspect_factory` runs the real golangci-lint binary per package, hermetically, and where its findings can differ from `golangci-lint run` over the module.

## Design

The approach is aspect-build/rules_lint PR #901's (a draft, forked and owned here), changed where golangci-lint's internals required it.

1. rules_go's `go_pkg_info_aspect` writes a `*.pkg.json` per Go target (sources, import map, export data), the same metadata its editor driver uses. The golangci-lint aspect `requires` it.
2. Per target, an action runs golangci-lint with `GOPACKAGESDRIVER` set to a static driver (`private/driver`). The driver answers go/packages from the staged metadata files listed in a config the aspect writes. It runs no go command, no Bazel and no network. Query patterns are ignored; the roots come from the config.
3. The driver gives every package its sources and its export data: the compiler's `.x` for Bazel targets, the precompiled `.a` for the standard library. It adds standard library imports from the import clauses (rules_go's metadata lists only Bazel deps), filters sources by build constraints for the target GOOS, GOARCH, `@rules_go//go/config:tags` and cgo setting, splits a go_test's external test files (`package x_test`) into their own package, and keeps a go_test's generated test main apart (rules_go gives it the test's ID).
4. golangci-lint runs with empty caches (`GOCACHE`, `GOLANGCI_LINT_CACHE`), a private `TMPDIR` and `HOME`, `GOPROXY=off`, `GOTOOLCHAIN=local`, `GOWORK=off` and `GOMAXPROCS=1`. Its JSON output becomes a report: one `path:line:col: text (linter)` per finding, empty when clean. A run that does not finish (exit status other than 0 or 1, or an error in the JSON) becomes a finding, so it fails the test.
5. `golangci_lint_test` merges the reports of everything its `srcs` reach and fails on any finding.

### Differences from PR #901

- Dependencies are not export-only. With an empty cache, golangci-lint computes analysis facts for every dependency from source (`loadImportedPackageWithFacts` in `pkg/goanalysis/runner_loadingpackage.go`): it loads export data, finds no cached facts, resets the package and type-checks its sources. A dependency without sources becomes an empty package, and every use of it a `typecheck` error ("undefined: strings.ToUpper"). So the standard library's and every dependency's sources are action inputs.
- The config and the package's own sources are copied to a symlink-free mirror. golangci-lint resolves symlinks in its config path and working directory (`fsutils.EvalSymlinks`) but not in source paths, and computes the relative paths exclusion rules match from both. In a sandbox every input is a symlink into the source tree, so the config's directory resolved outside the sandbox, and golangci-lint read the real tree's go.mod.
- The driver reads a config listing the metadata files instead of a directory of copies named by basename, which collide when two packages share a name.
- golangci-lint's lock file lives in `TMPDIR`; without a private one, parallel lint actions wait on each other ("parallel golangci-lint is running").
- No Python and no SARIF rewriting: a Go report tool (`private/report`) writes the report.

### Test variants

golangci-lint lints a package that has tests only as its test variant (the package plus its `_test.go` files), not also on its own. A function only tests call is therefore not `unused`. Linted alone, the library would report it. So each report carries a `.covers` file: `variant=lib` or `variant=test`, then the files it covers. When the test merges reports, findings in a file a test variant covers come from test-variant reports only. A go_test that embeds a library covers the library's files.

This matches golangci-lint only when the `srcs` of the test reach the go_test. A library whose tests are not reached is linted alone (`//tests/golangci:library_alone_proof` shows the difference).

## Parity

`//tests/golangci:parity_test` runs the oracle, golangci-lint over a sandboxed copy of the fixture module with the go command loading packages (afakt's offline vendor-mode gate: `GOFLAGS=-mod=vendor` when `vendor/` exists, `GOPROXY=off`, `GOTOOLCHAIN=local`, fresh caches, sources collected through the build graph), and requires the merged aspect reports to hold exactly its findings. The fixture covers errcheck, gocritic, govet, ineffassign, misspell, revive, staticcheck, unparam and unused; a govet printf finding that needs a fact from another package; an internal and an external test package; a function used only by tests; a `//nolint`; a path exclusion rule; and a `//go:build ignore` file. Result: 11 of 11 findings identical.

The smoke module (`e2e/smoke`) repeats the comparison for a consumer with an external module (go-cmp through go_deps), with the oracle reading modules from a `go_mod_proxy` directory: 2 of 2 identical, the `//nolint` and the excluded file absent from both.

The one divergence found, the test-variant case above, is fixed by the merge.

## Gaps

- **Facts are recomputed, not shared.** Every action type-checks and analyzes its whole dependency closure, standard library included, from source, because golangci-lint's fact cache starts empty. That is golangci-lint's cold-run cost per package, and it is why dependency sources are inputs: editing a package re-lints its dependents. Seeding each action's `GOLANGCI_LINT_CACHE` with its dependencies' cache entries would avoid the recomputation, but golangci-lint keys entries by absolute file paths, which differ between sandboxes. Not attempted.
- **Cross-package linters.** Each action sees one package (two for a go_test with an external test package). Analysis facts flow from dependencies, but a linter that compares the packages of a run with each other, such as `dupl` or `goconst`, sees one package at a time. Run-wide limits such as `max-same-issues` and `max-issues-per-linter` apply per package.
- **One configuration.** The driver filters sources for the target platform and rules_go's build tags. `GOOS`/`GOARCH` variants and tag variants need one build per configuration (`--platforms`, `--@rules_go//go/config:tags=...`); files for other platforms are never linted. golangci-lint's own `run.build-tags` are not applied: Bazel decides which files a package has.
- **cgo.** Packages with cgo get rules_go's generated sources from the metadata, but the driver does not run cgo and golangci-lint's `cgo` handling of original file positions is untested here. The oracle runs with `CGO_ENABLED=0`.
- **Generated code.** Generated sources of a target (from `bazel-out`) are not mirrored, so reports show them by absolute path and path-based exclusion rules written for workspace paths will not match them. golangci-lint's generated-file exclusion by header applies as usual. Untested here.
- **Go version.** A driver response carries no module data, so go/packages type-checks with the SDK's version (`go1.27`), not go.mod's `go` line. golangci-lint itself reads go.mod when `go_mod` is set; without it, it uses the SDK's version.
- **Version skew.** golangci-lint 2.15.0 is built with go1.27.0 and reads the export data of the SDK the consumer pins. An SDK newer than golangci-lint's Go can produce export data it cannot read.
- **GOMAXPROCS=1** makes each action single-threaded, which avoids a known race in x/tools' export data importer (golang/go#34895, #67725, #70015) at the cost of per-package wall time; Bazel's parallelism across packages makes up for most of it.
- **Inputs.** Each action takes the whole standard library's sources (about 7,000 files) as inputs, which costs sandbox setup time locally; remote execution caches the input tree.
- **Private rules_go API.** `GoStdLib` is loaded from `@rules_go//go/private:providers.bzl`, and `go_pkg_info_aspect` and its `.pkg.json` format are rules_go internals, so a rules_go upgrade can break the aspect.
- **Not fix mode.** `golangci-lint run --fix` is not wired; use the `golangci_fmt` formatter for formatting.

## Timings

Measured on an Apple M-series machine with 16 cores while it ran other work (load average about 160). These figures show what reruns and roughly what it costs, not absolute speed.

| Run | Time |
| --- | --- |
| One package (`clean`, imports `strings`), golangci-lint alone, `GOMAXPROCS=1` | 12.2 s wall, 2.1 s user CPU, 290 MB peak |
| The same, `GOMAXPROCS=16` | 4.5 s wall, 2.0 s user CPU |
| Lint action per fixture target, cold, `--jobs=1` | 14 to 20 s wall, 300 to 400 MB peak |
| The oracle, whole fixture module in one run | 25 s wall |
| Warm: every report cached, `bazel build` of all reports | 0.4 s |
| Incremental: one comment changed in package `b` | `b` and `b_test` re-run (6 to 8 s each); `a` and `clean` cached |

Wall time on that machine is mostly waiting for CPU: the 2 s of CPU per package is the better guide, most of it golangci-lint building SSA and facts for the standard library closure (`buildir`, `printf`).
