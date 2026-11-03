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
- The config and the package's own sources are copied to a symlink-free mirror. golangci-lint resolves symlinks in its config path and working directory (`fsutils.Getwd`, `fsutils.EvalSymlinks` and `fsutils.ShortestRelPath` in `pkg/fsutils/fsutils.go`, used by `BaseLoader.setConfigDir` in `pkg/config/base_loader.go`) but not in source paths, and computes the relative paths exclusion rules match from both. In a sandbox every input is a symlink into the source tree, so the config's directory resolved outside the sandbox, and golangci-lint read the real tree's go.mod.
- The driver reads a config listing the metadata files instead of a directory of copies named by basename, which collide when two packages share a name.
- golangci-lint's lock file lives in `TMPDIR` (`runCommand.acquireFileLock` in `pkg/commands/run.go`); without a private one, parallel lint actions wait on each other ("parallel golangci-lint is running").
- No Python and no SARIF rewriting: a Go report tool (`private/report`) writes the report.

### Test variants

golangci-lint lints a package that has tests only as its test variant (the package plus its `_test.go` files), not also on its own. A function only tests call is therefore not `unused`. Linted alone, the library would report it. So each report carries a `.covers` file: `variant=lib` or `variant=test`, then the files it covers. When the test merges reports, findings in a file a test variant covers come from test-variant reports only. A go_test that embeds a library covers the library's files.

This matches golangci-lint only when the `srcs` of the test reach the go_test. A library whose tests are not reached is linted alone (`//tests/golangci:library_alone_proof` shows the difference).

### Configurations

A go_binary with `pure`, `static`, `goos` or `goarch` set transitions its dependencies, so a package two binaries share can be built, and linted, in two configurations in one build. Each configuration gets its own action and report (the output paths differ), and the test merges identical findings, so a finding in the shared package is reported once (`e2e/smoke` `//:shared_finding_once_proof`, with cmd/b built `pure`). Findings that differ between configurations, such as one in a file only one platform compiles, are each reported.

rules_go lists the standard library with `go list -compiled` only when cgo is on, so in a cgo-off configuration its metadata has no `CompiledGoFiles`, and go/packages would type-check every standard package empty ("undefined: os.Remove"). The driver uses `GoFiles` then, which with cgo off are exactly what the compiler compiles.

### Packages nothing reaches

The aspect lints what `srcs` reach, so a package that no listed binary or test depends on is never linted. Two guards: a target in `srcs` that reaches no Go target of the main repository fails analysis; and with `expect_linted = [":repo_files"]` the test fails on every `.go` file no report covers, naming it. The guard compares files rather than packages so it needs no package list to maintain, and also catches a file a build constraint or a BUILD file leaves out of every target. A list of expected packages would drift; the files are already there.

## Parity

`//tests/golangci:parity_test` runs the oracle, golangci-lint over a sandboxed copy of the fixture module with the go command loading packages (afakt's offline vendor-mode gate: `GOFLAGS=-mod=vendor` when `vendor/` exists, `GOPROXY=off`, `GOTOOLCHAIN=local`, fresh caches, sources collected through the build graph), and requires the merged aspect reports to hold exactly its findings. The fixture covers errcheck, gocritic, govet, ineffassign, misspell, revive, staticcheck, unparam and unused; a govet printf finding that needs a fact from another package; an internal and an external test package; a function used only by tests; a `//nolint`; a path exclusion rule; and a `//go:build ignore` file. Result: 11 of 11 findings identical.

The smoke module (`e2e/smoke`) repeats the comparison for a consumer with an external module (go-cmp through go_deps), with the oracle reading modules from a `go_mod_proxy` directory: 2 of 2 identical, the `//nolint` and the excluded file absent from both.

The one divergence found, the test-variant case above, is fixed by the merge.

## Hermeticity

- Nothing outside the inputs is read. `//tests/golangci:outside_go_mod_unread_proof` lints a package whose directory in the source tree holds a go.mod the aspect is not given; that go.mod's `go 1.21` turns intrange off. The aspect reports the intrange finding, so it did not read the file. `//tests/golangci:outside_go_mod_read_changes_result_proof` is the control: golangci-lint run the ordinary way, which does read it, finds nothing.
- Sandboxed and unsandboxed runs agree. On the smoke module (both binaries, their planted variants, `dirty` and `lib_test`: 18 lint actions over two configurations), a cold sandboxed build and a cold `--spawn_strategy=local` build after `bazel clean` wrote byte-identical reports and `.covers` files.
- Reports do not depend on cache state. Two cold sandboxed builds (each after `bazel clean`) and a warm rebuild gave byte-identical reports. Each action starts from empty golangci-lint and Go caches of its own, so no earlier run can feed it.
- Findings outside the main repository are dropped from reports: a dependency or the standard library is not the repository's to fix. A `typecheck` error in one is the exception. It means the dependency did not load, and everything using it was checked against an empty package, so the run counts as not completed and fails (`private/report` tests). Dropping those silently would have hidden the cgo-off standard library bug above.

## Gaps

- **Facts are recomputed, not shared.** Every action type-checks and analyzes its whole dependency closure, standard library included, from source, because golangci-lint's fact cache starts empty. That is golangci-lint's cold-run cost per package, and it is why dependency sources are inputs: editing a package re-lints its dependents. Seeding each action's `GOLANGCI_LINT_CACHE` with its dependencies' cache entries would avoid the recomputation, but golangci-lint keys entries by absolute file paths, which differ between sandboxes. Not attempted.
- **Cross-package linters.** Each action sees one package (two for a go_test with an external test package). Analysis facts flow from dependencies, but a linter that compares the packages of a run with each other, such as `dupl` or `goconst`, sees one package at a time. Run-wide limits such as `max-same-issues` and `max-issues-per-linter` apply per package.
- **Configurations the build does not reach.** The driver filters sources for each action's configuration (platform, rules_go's build tags, cgo). Configurations the build graph reaches are linted (see Configurations); others need their own build (`--platforms`, `--@rules_go//go/config:tags=...`), and files for platforms nothing builds are never linted. golangci-lint's own `run.build-tags` are not applied: Bazel decides which files a package has.
- **cgo.** Packages with cgo get rules_go's generated sources from the metadata, but the driver does not run cgo and golangci-lint's `cgo` handling of original file positions is untested here. The oracle runs with `CGO_ENABLED=0`.
- **Generated code.** Generated sources of a target (from `bazel-out`) are not mirrored, so reports show them by absolute path and path-based exclusion rules written for workspace paths will not match them. golangci-lint's generated-file exclusion by header applies as usual. Untested here.
- **Go version.** A driver response carries no module data, so go/packages type-checks with the SDK's version (`go1.27`), not go.mod's `go` line. golangci-lint itself reads go.mod when `go_mod` is set; without it, it uses the SDK's version.
- **Version skew.** golangci-lint 2.15.0 is built with go1.27.0 and reads the export data of the SDK the consumer pins. An SDK newer than golangci-lint's Go can produce export data it cannot read.
- **GOMAXPROCS=1** makes each action single-threaded, which avoids a known race in x/tools' export data importer (golang/go#34895, #67725, #70015) at the cost of per-package wall time; Bazel's parallelism across packages makes up for most of it.
- **Inputs.** Each action takes the whole standard library's sources (about 7,000 files) as inputs, which costs sandbox setup time locally; remote execution caches the input tree.
- **Private rules_go API.** `GoStdLib` is loaded from `@rules_go//go/private:providers.bzl`, and `go_pkg_info_aspect` and its `.pkg.json` format are rules_go internals, so a rules_go upgrade can break the aspect. This module pins rules_go 0.65.0 exactly (`single_version_override`, binding when it is the root module) and tells consumers to stay on it.
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

Multi-binary smoke module (`e2e/smoke`, 18 lint actions, two configurations), same machine, load average about 150, measured from Bazel's execution log:

| Run | Result |
| --- | --- |
| Cold build of all 18 reports, sandboxed | 69 s and 78 s wall (two runs); actions 4 to 15 s each, mean 9.6 to 11.7 s |
| The same, `--spawn_strategy=local` | 86 s wall; actions mean 9.6 s |
| Warm rebuild | 0.3 s |
| Shared package `internal/shared`, per configuration | 6,600 to 7,400 inputs, about 488 MB; 8.6 to 11 s cold sandboxed, 7.4 to 7.6 s local |

Of an action's inputs, 5,931 files (95 MB) are standard library sources, about 1,400 files (285 MB) are the precompiled standard library (including 70 MB of compiler tools nothing reads, part of the same tree artifact), and 81 MB is golangci-lint. All are the same files for every action, stored once; what an action pays for them is the sandbox's symlink per input. Sandboxed and local action times are the same within noise, so that cost is small next to golangci-lint's own work, and a single shared standard library tree artifact would not buy much locally. With remote execution the input tree is cached by digest.

Wall time on that machine is mostly waiting for CPU: the 2 s of CPU per package is the better guide, most of it golangci-lint building SSA and facts for the standard library closure (`buildir`, `printf`).
