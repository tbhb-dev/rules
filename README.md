# `tbhb_rules`

Shared Bazel rules for tbhb-dev repositories: whole-tree lint tests with pinned tools, formatters, quality gates, and the plumbing around them. The root module, `tbhb_rules`, holds the checks every repository uses, with one package per family:

| Family | Load from | Contents |
| --- | --- | --- |
| format | `@tbhb_rules//format:defs.bzl` | `formatter`, `format` (fix and `.check` runners), `format_test`, and ready formatters `//format:shfmt`, `:buildifier`, `:tombi`, `:rumdl` and `:ryl` |
| lint | `@tbhb_rules//lint:defs.bzl` | `gitleaks_test`, `gitleaks_history`, `ryl_test`, `tombi_test`, `rumdl_test`, `editorconfig_checker_test`, `actionlint_test`, `zizmor_test`, `shellcheck_test`, `shfmt_test`, `bats_test`, `codeowners_test`, `vale_test`, `vale_sync`, `cspell_test`, and the generic `tree_check_test` |
| quality | `@tbhb_rules//quality:defs.bzl` | `mutation_gate_test` and its `MutationReportInfo` |
| repo | `@tbhb_rules//repo:defs.bzl` | `repo_files`, `repo_layout_test` |
| runtime | `@tbhb_rules//runtime:defs.bzl` | the pinned Python runtime (python-build-standalone and uv) that the Python-based checks share |
| testing | `@tbhb_rules//testing:defs.bzl` | `expect_failure_test` |

Language rules live in nested modules. A repository takes on only the toolchains it uses: `tbhb_rules_go` in `go/` and `tbhb_rules_python` in `python/`.

The modules require Bazel 9 or newer (`bazel_compatibility = [">=9.0.0"]`), the only release line tbhb-dev repositories use.

Load only the `defs.bzl` files. Everything under `private/` is internal and can change without notice.

## Use

The module isn't on the Bazel Central Registry yet. A root module consumes it from Git:

```starlark
bazel_dep(name = "tbhb_rules")
git_override(
    module_name = "tbhb_rules",
    commit = "<commit>",
    remote = "https://github.com/tbhb-dev/rules.git",
)
```

To develop against a local clone, put `common --override_module=tbhb_rules=/path/to/rules` in `.bazelrc.user`.

### Whole-tree checks

`glob()` stops at package boundaries, so a check over the whole repository needs every package to contribute its files. Call `repo_files()` in every `BUILD.bazel`, root included. Each call collects its package's files plus the `repo_files` target of each direct subpackage, so a package that forgets the call breaks analysis of its parent instead of dropping out of the checks unnoticed.

List directories without source files, such as `.git`, `bazel-*`, `.venv`, and tool caches, in `ignore_directories` in `REPO.bazel`, and no glob enters them. `repo_files` takes an `exclude` list for loose files such as `.DS_Store`.

```starlark
load("@tbhb_rules//lint:defs.bzl", "gitleaks_test", "ryl_test")
load("@tbhb_rules//repo:defs.bzl", "repo_files")

repo_files()

gitleaks_test(
    name = "gitleaks_test",
    srcs = [":repo_files"],
    config = ".gitleaks.toml",
)

ryl_test(
    name = "ryl_test",
    srcs = [":repo_files"],
    config = ".ryl.toml",
)
```

Each test copies its inputs, dereferenced, into a scratch tree at their repository-relative paths and runs the tool there. Configs that name other files still resolve, and the tool can't write into your sources or follow a symlink out of the tree. The copy must hold at least `min_files` files (default 1) and more than zero bytes, or the test fails and reports what it found. A check that scanned nothing doesn't prove anything. `gitleaks_test` also requires gitleaks to report a non-zero scanned byte count.

Every macro takes `srcs`, an optional `config`, `data` for other files the tool reads, `tool` to override the binary for one target, and `strip_prefix` to check a subtree as if it were the repository root. Other keywords go to `tree_check_test`.

Notes on individual tools:

- `tombi_test` creates `<name>.format` and `<name>.lint`, with a `<name>` suite. tombi runs offline, and some of its embedded schemas refer to others by URL. Pass pinned copies in `schemas = {url: label}`, such as an `http_file` with a `sha256`. Otherwise those references become warnings, which fail the lint.
- `actionlint_test` puts the pinned shellcheck on PATH, so the `run:` block checks can't silently vanish.
- `zizmor_test` runs the offline audits only. The online audits need the network and a token, so they belong outside the test graph.
- `gitleaks_test` scans the working tree. `gitleaks_history` scans the Git history, with `bazel run` (in CI, after a full-depth checkout). It fails when gitleaks walks no commits of a history with content, which gitleaks itself reports as success.

### Failure proofs

Only a run on bad input that ends in the expected rejection, for the right reason, proves that a check rejects bad input. `expect_failure_test` wraps a test and passes only when that test fails and its output matches `pattern`, an extended regular expression:

```starlark
load("@tbhb_rules//testing:defs.bzl", "expect_failure_test")

gitleaks_test(
    name = "planted_secret",
    srcs = [":fixture_with_a_fake_key"],
    tags = ["manual"],
)

expect_failure_test(
    name = "planted_secret_is_found",
    pattern = "leaks found: [1-9]",
    test = ":planted_secret",
)
```

Tag the wrapped test `manual` so `bazel test //...` doesn't run it on its own. The wrapper gives it its own `TEST_TMPDIR` and `HOME` and forwards its `env`. The wrapped test can't write this test's result files. Bazel doesn't expose a provider for a test's `args`, so set those on the `expect_failure_test` instead. A failed proof prints the wrapped test's exit status and output.

### Tool pins

Each tool binary is a literal `http_archive` or `http_file` pin in `pins/extensions.bzl`, one per tool and platform, so Renovate can move a version. The pins cover macOS arm64, Linux x86_64, Linux arm64, and Windows x86_64. Each tool has a hub repository, `tbhb_rules_<tool>`, whose `//:<tool>` target picks the binary for the target platform, and the rules use only those labels. buildifier comes from the `buildifier_prebuilt` module.

To swap one tool for your own build, point its hub at a repository with a `//:<tool>` target:

```starlark
tools = use_extension("@tbhb_rules//pins:extensions.bzl", "tools")
override_repo(tools, tbhb_rules_gitleaks = "my_gitleaks")
```

To refer to a pinned binary yourself, add `use_repo(tools, "tbhb_rules_gitleaks")`.

### Windows

The rules' executables are Bash scripts. On Windows each runs through a `.bat` launcher with the Bash of the shell `toolchain`, so set `BAZEL_SH` to an MSYS2 or Git for Windows `bash.exe`. The scripts read their files from the `runfiles` tree, so add `common:windows --enable_runfiles` (with `common --enable_platform_specific_config`) to your `.bazelrc`.

## Develop

mise provides bazelisk, and uv for the interim pull request scripts (`mise install`). Bazel pins everything else.

| Command | Checks |
| --- | --- |
| `bazelisk test //...` | buildifier, this repository's lint, shell and Python gates (in `tools/`), run on its own rules |
| `(cd e2e/smoke && bazelisk test //...)` | the rules as a consumer sees them, including the failure proofs |
| `bazelisk run //:format` | rewrites files with the formatters, and `//:format.check` only checks |
| `(cd go && bazelisk test //...)`, `(cd python && bazelisk test //...)` | the nested language modules, each with its own consumers under `e2e/` |
| `mise run test` | every command in this table except the format runs |

`.github/workflows/ci.yml` lists the complete gate set.
