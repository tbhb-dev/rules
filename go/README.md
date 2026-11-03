# tbhb_rules_go

Go checks for tbhb-dev repositories, as a Bazel module nested in tbhb_rules (documented in its own `README.md`): golangci-lint per package, deadcode, go-arch-lint import contracts, `go mod tidy`, and a golangci-lint formatter. Each runs the real tool with the repository's own config, in a sandbox, with no network.

Load everything from `@tbhb_rules_go//:defs.bzl`. Everything under `private/` is internal.

## Quickstart

Neither module is on the Bazel Central Registry yet, and overrides in a dependency's MODULE.bazel do not apply, so a consumer overrides both (with a commit of this repository).

The three files below are a complete consumer. `e2e/quickstart` holds them verbatim (after a license header) and its `//:readme_test` fails when they drift apart, so they build and pass as written.

<!-- quickstart: MODULE.bazel -->
```starlark
bazel_dep(name = "rules_go", version = "0.65.0")
bazel_dep(name = "gazelle", version = "0.54.0")
bazel_dep(name = "tbhb_rules")
git_override(
    module_name = "tbhb_rules",
    commit = "<commit>",
    remote = "https://github.com/tbhb-dev/rules.git",
)

bazel_dep(name = "tbhb_rules_go")
git_override(
    module_name = "tbhb_rules_go",
    commit = "<commit>",
    remote = "https://github.com/tbhb-dev/rules.git",
    strip_prefix = "go",
)

# The Go SDK named by go.mod's toolchain line.
go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
go_sdk.from_file(go_mod = "//:go.mod")

# The module's dependencies, for the build.
go_deps = use_extension("@gazelle//:extensions.bzl", "go_deps")
go_deps.from_file(go_mod = "//:go.mod")
use_repo(go_deps, "com_github_google_go_cmp")

# The same modules as a GOPROXY directory, for go_mod_tidy_test.
go_mod_proxy = use_extension("@tbhb_rules_go//:extensions.bzl", "go_mod_proxy")
go_mod_proxy.from_file(
    name = "go_mod_proxy",
    go_sum = "//:go.sum",
)
use_repo(go_mod_proxy, "go_mod_proxy")
```

<!-- quickstart: tools/lint/linters.bzl -->
```starlark
load("@tbhb_rules_go//:defs.bzl", "golangci_lint_aspect_factory", "golangci_lint_test_factory")

golangci_lint = golangci_lint_aspect_factory(
    config = "//:.golangci.yml",
    go_mod = "//:go.mod",
)

golangci_lint_test = golangci_lint_test_factory(golangci_lint)
```

<!-- quickstart: BUILD.bazel -->
```starlark
load("@tbhb_rules//repo:defs.bzl", "repo_files")
load("@tbhb_rules_go//:defs.bzl", "go_arch_lint_test", "go_deadcode_test", "go_mod_tidy_test")
load("//tools/lint:linters.bzl", "golangci_lint_test")

repo_files()

# Every binary and test of the module.
GO_TARGETS = [
    "//cmd/app",
    "//pkg/thing:thing_test",
]

golangci_lint_test(
    name = "golangci_lint_test",
    srcs = GO_TARGETS,
    expect_linted = [":repo_files"],
)

go_deadcode_test(
    name = "deadcode_test",
    srcs = GO_TARGETS,
)

go_arch_lint_test(
    name = "go_arch_lint_test",
    srcs = GO_TARGETS,
    config = ".go-arch-lint.yml",
    go_mod = "go.mod",
)

go_mod_tidy_test(
    name = "go_mod_tidy_test",
    srcs = [":repo_files"],
    go_mod = "go.mod",
    go_sum = "go.sum",
    proxy = "@go_mod_proxy//:proxy",
)
```

The module needs `rules_go` 0.65.0 exactly and a Go SDK from the consumer's `go_sdk` extension. It loads `GoStdLib` from rules_go's private `providers.bzl` and reads rules_go's `.pkg.json` metadata, so it is tested against that one version; a consumer whose graph selects another rules_go may break. golangci-lint (2.15.0) and go-arch-lint (1.19.1) are literal `http_archive` calls per platform in `private/tools.bzl`, which Renovate can bump; every rule takes another binary through `tool`. deadcode is built from `golang.org/x/tools` through gazelle's `go_deps`, and a consumer's go.mod wins version selection. Bazel 9 or later.

## golangci-lint

Declare an aspect and a test rule once, in a `.bzl` file:

```starlark
# tools/lint/linters.bzl
load("@tbhb_rules_go//:defs.bzl", "golangci_lint_aspect_factory", "golangci_lint_test_factory")

golangci_lint = golangci_lint_aspect_factory(
    config = "//:.golangci.yml",
    go_mod = "//:go.mod",
)

golangci_lint_test = golangci_lint_test_factory(golangci_lint)
```

```starlark
# BUILD.bazel
load("//tools/lint:linters.bzl", "golangci_lint_test")

golangci_lint_test(
    name = "golangci_lint_test",
    srcs = ["//cmd/app", "//pkg/thing:thing_test"],
)
```

The aspect runs golangci-lint once per `go_library`, `go_binary` and `go_test` of the main repository, as its own cached action, and follows `deps` and `embed`, so listing binaries and tests reaches their libraries. The test fails when any report holds a finding and prints them all; it also fails when golangci-lint did not finish (a broken config, a load error). `//nolint` directives and the config's exclusions work as they do outside Bazel.

A package shared by several binaries is linted once per configuration it is built in: a `go_binary` with `pure`, `static`, `goos` or `goarch` set builds its dependencies in a configuration of its own. The test reports a finding that several configurations share once.

A package nothing in `srcs` reaches is not linted, and nothing says so unless you ask. Every target in `srcs` must reach a Go target of the main repository (analysis fails otherwise). To catch packages no binary or test reaches, pass the repository's files:

```starlark
golangci_lint_test(
    name = "golangci_lint_test",
    srcs = ["//cmd/a", "//cmd/b", "//pkg/thing:thing_test"],
    expect_linted = [":repo_files"],
    expect_linted_exclude = ["*/fixtures/*"],
)
```

The test then fails on every `.go` file in `expect_linted` that no report covers (`not linted: pkg/new/new.go`), except files under `testdata/` or `vendor/` and those matching `expect_linted_exclude` (bash globs; `*` matches `/`). It compares files, not packages, so it also notices a file a constraint or a BUILD file leaves out of every target.

Reports without a test: `bazel build //... --aspects=//tools/lint:linters.bzl%golangci_lint --output_groups=golangci_lint`.

Factory arguments: `config` (required), `go_mod` (runs golangci-lint from the module root, as you would by hand, and takes the Go version from it), `data` (files the config names), `args` (extra `run` flags), `tool`, `rule_kinds`. Pass labels as `Label(...)` or as `//` strings, which mean the main repository.

How it works and what it cannot see: [docs/golangci-lint.md](docs/golangci-lint.md).

## deadcode

```starlark
go_deadcode_test(
    name = "deadcode_test",
    srcs = ["//cmd/app", "//pkg/thing:thing_test"],
)
```

Runs `deadcode -test` once over every main-repository package `srcs` reach, from all the `main` packages and test mains among them together, through the same static driver as the aspect. List every binary and test: a function only one binary calls is live, but checked from another binary alone it looks dead. Any finding fails. `filter` sets deadcode's `-filter` (by default, exactly the main-repository packages); `test = False` drops `-test`; `deadcode_args` adds flags.

## go-arch-lint

```starlark
go_arch_lint_test(
    name = "go_arch_lint_test",
    srcs = ["//cmd/a", "//cmd/b", "//pkg/thing:thing_test"],
    config = ".go-arch-lint.yml",
    go_mod = "go.mod",
)
```

Checks the import contracts of a [go-arch-lint](https://github.com/fe3dback/go-arch-lint) config (version 3): layers, independence of siblings, leaves, and "only X may import Y", which follows from go-arch-lint's allow lists. It copies `go_mod`, `config` and the main-repository Go sources `srcs` reach into a scratch tree, laid out relative to go.mod's directory, and runs `go-arch-lint check` there: one whole-module run, not per package, since the contracts are graph-wide and a run takes milliseconds. go-arch-lint parses import clauses and reads go.mod; it gets no go command, module cache or network.

- The config must set `allow.deepScan: false`; deep scanning runs `go list`, so the test rejects a config without it.
- A file in no component fails the run, so a new package needs a deliberate place. A leaf needs `mayDependOn: [itself]`, because go-arch-lint rejects an empty list.
- Only what `srcs` reach is checked, and the test fails when that is no Go file at all.
- `tool` takes another go-arch-lint binary; the test's `args` go to `go-arch-lint check`.

Third-party and standard library bans stay with golangci-lint's depguard. Bazel `visibility` can back the "only X may import Y" rule at build time (for example `# gazelle:default_visibility //cmd:__subpackages__` in a feature's directory), but it cannot express sibling independence; this module does not generate it.

## go mod tidy

```starlark
# MODULE.bazel
go_mod_proxy = use_extension("@tbhb_rules_go//:extensions.bzl", "go_mod_proxy")
go_mod_proxy.from_file(name = "go_mod_proxy", go_sum = "//:go.sum")
use_repo(go_mod_proxy, "go_mod_proxy")
```

```starlark
# BUILD.bazel
go_mod_tidy_test(
    name = "go_mod_tidy_test",
    srcs = [":repo_files"],
    go_mod = "go.mod",
    go_sum = "go.sum",
    proxy = "@go_mod_proxy//:proxy",
)
```

Runs `go mod tidy -diff` and `go mod verify` once per module, however many binaries it has, over a copy of the module (go.mod's directory need not be the repository root; the copy is laid out relative to it), with a fresh module cache and `GOPROXY` pointed at a directory the extension fetched from the modules go.sum lists. The go command checks every download against go.sum, so a tampered sum or module fails, and a requirement go.sum lacks fails as untidy.

## Formatter

`@tbhb_rules_go//:golangci_fmt` is a `formatter` for `@tbhb_rules//format:defs.bzl`: `golangci-lint fmt` over `*.go`, with the formatters the workspace's `.golangci.yml` enables (gci, gofumpt, goimports, golines). It runs with the Go SDK's `go` on PATH, which gci and goimports need.

## Formatting this module

`bazel run //:format` in `go/` rewrites this module's files with golangci_fmt and the parent module's buildifier, shfmt, rumdl and ryl; `//:format.check` and `//:format_test` check them. `.editorconfig`, `.rumdl.toml` and `.ryl.toml` link to the parent's, so the test's copy reads the same settings as a run in the tree.

## Development

```sh
cd go && bazelisk test //...              # rules, fixtures, proofs, parity
cd go/e2e/smoke && bazelisk test //...    # a consumer with an external dependency
```

Every check has a proof: a `manual` target over a planted defect, wrapped in an `expect_failure_test` that requires the stated reason. `//tests/golangci:parity_test` and the smoke module's `//:parity_test` compare the aspect's findings with golangci-lint run the ordinary way over the same module.
