# tbhb_rules_go

Go checks for tbhb-dev repositories, as a Bazel module nested in [tbhb_rules](../README.md): golangci-lint per package, deadcode, `go mod tidy`, and a golangci-lint formatter. Each runs the real tool with the repository's own config, in a sandbox, with no network.

Load everything from `@tbhb_rules_go//:defs.bzl`. Everything under `private/` is internal.

```starlark
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
```

Neither module is on the Bazel Central Registry yet, and overrides in a dependency's MODULE.bazel do not apply, so a consumer overrides both.

The module needs `rules_go` (0.65.0 or later) and a Go SDK from the consumer's `go_sdk` extension. Tool pins (golangci-lint 2.15.0) join the shared `@multitool` hub, so a consumer's own `multitool.lock.json` can override them. deadcode is built from `golang.org/x/tools` through gazelle's `go_deps`, and a consumer's go.mod wins version selection.

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

The aspect runs golangci-lint once per `go_library`, `go_binary` and `go_test` of the main repository, as its own cached action, and follows `deps` and `embed`, so listing binaries and tests reaches their libraries. The test fails when any report holds a finding and prints them all; it also fails when it linted nothing, and when golangci-lint did not finish (a broken config, a load error). `//nolint` directives and the config's exclusions work as they do outside Bazel.

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

Runs `deadcode -test` over every main-repository package `srcs` reach, from the `main` packages and the test mains among them, through the same static driver as the aspect. Any finding fails. `filter` sets deadcode's `-filter` (by default, exactly the main-repository packages); `test = False` drops `-test`; `deadcode_args` adds flags.

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

Runs `go mod tidy -diff` and `go mod verify` over a copy of the module, with a fresh module cache and `GOPROXY` pointed at a directory the extension fetched from the modules go.sum lists. The go command checks every download against go.sum, so a tampered sum or module fails, and a requirement go.sum lacks fails as untidy.

## Formatter

`@tbhb_rules_go//:golangci_fmt` is a `formatter` for `@tbhb_rules//format:defs.bzl`: `golangci-lint fmt` over `*.go`, with the formatters the workspace's `.golangci.yml` enables (gci, gofumpt, goimports, golines). It runs with the Go SDK's `go` on PATH, which gci and goimports need.

## Development

```sh
cd go && bazelisk test //...              # rules, fixtures, proofs, parity
cd go/e2e/smoke && bazelisk test //...    # a consumer with an external dependency
```

Every check has a proof: a `manual` target over a planted defect, wrapped in an `expect_failure_test` that requires the stated reason. `//tests/golangci:parity_test` and the smoke module's `//:parity_test` compare the aspect's findings with golangci-lint run the ordinary way over the same module.
