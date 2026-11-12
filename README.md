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

Language and diagram rules live in nested modules. A repository takes on only the toolchains it uses: `tbhb_rules_go` in `go/`, `tbhb_rules_python` in `python/`, `tbhb_rules_typescript` in `typescript/`, `tbhb_rules_cloudflare` in `cloudflare/`, which builds on the TypeScript module, `tbhb_rules_astro` in `astro/`, `tbhb_rules_playwright` in `playwright/`, which pins Playwright's browsers, `tbhb_rules_storybook` in `storybook/`, which builds, tests and serves Storybooks on those browsers, `tbhb_rules_ansible` in `ansible/`, which checks Ansible playbooks, roles and inventories, `tbhb_rules_tokens` in `tokens/`, which checks W3C design tokens and builds them into CSS with Terrazzo, `tbhb_rules_d2` in `diagrams/d2/`, and `tbhb_rules_swift` in `swift/`, which builds and tests Swift libraries, iOS simulator apps and macOS apps and needs a Mac with Xcode.

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

List directories without source files, such as `.git`, `.bazel-*` (and the old `bazel-*` links), `.venv`, and tool caches, in `ignore_directories` in `REPO.bazel`, and no glob enters them. `repo_files` takes an `exclude` list for loose files such as `.DS_Store`.

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
- `gitleaks_test` scans the working tree. `gitleaks_history` scans the Git history of every branch, with `bazel run` (in CI, after a full-depth checkout). `bazel run //:gitleaks_history -- --log-opts=HEAD` scans the full checked-out history. A leading `--merge-range` instead scans `HEAD^1..HEAD`: the pull request's own commits plus the merge commit, provided `HEAD` matches the full commit hash in `EXPECTED_HEAD`. Unset or different `EXPECTED_HEAD`, changes to `.gitleaks.toml` or `.gitleaksignore`, or unexpected Git state fall back to the full checked-out history, so tightened rules also meet old history. `repo-checks.yml` uses range mode for pull requests with `EXPECTED_HEAD` set to `github.sha` and the full scan for every other event. The private config (`GITLEAKS_CONFIG_TOML`) changes out of band. The next full scan (push to main) applies its changes to old history, the same accepted limit as a rules version bump. It fails when gitleaks walks no commits of a range with content, which gitleaks itself reports as success. `bazel run @tbhb_rules//lint:gitleaks_text < file` scans text, such as a pull request's body, under the workspace's `.gitleaks.toml`.
- `bazel run @tbhb_rules//lint:commit_identity -- BASE HEAD` fails on any commit in `BASE..HEAD` whose author and committer aren't one of the allowed pairs in `ALLOWED_PAIRS`, in `lint/private/commit_identity.bzl`. Commits with `agent@tonyburns.net` as either email also require valid `Generated-by` or `Assisted-by` identity trailers and forbid sign-off and co-author lines. [`Commit identity`](docs/reference/commit-identity.md) describes the grammar. `repo-checks.yml` runs it on a pull request's commits.

### Shared vocabulary

`cspell_test` and `vale_test` inherit the public tool names in `lint/vocabulary/words.txt`, including `workerd`, without a word list in each consuming repository. Add common public tool and product names there. Keep repository-specific terms in the consuming repository's own dictionaries or Vale vocabulary.

Both targets accept a trailing straight or curly apostrophe and `s` only when they accept the base word. cspell ignores just the suffix and still checks the base. Vale adds the shared `tbhb_rules` vocabulary alongside the configured vocabularies in its scratch copy and gives each accepted expression an optional possessive suffix. A misspelled base still fails both checks. Project configs, dictionaries, and pinned Vale packages continue to apply.

For cspell outside Bazel, import `lint/vocabulary/cspell.config.cjs` from a local rules checkout using [cspell's configuration imports](https://cspell.org/docs/Configuration/imports). The automatic Vale vocabulary applies to `vale_test`. `vale_sync` continues to sync style packages for editors. Vale's [vocabulary format](https://docs.vale.sh/keys/vocabularies) describes how to add local terms.

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

### Go

Binaries built with `rules_go` need a C/C++ toolchain. On Linux, register the zig toolchain from `hermetic_cc_toolchain` in your root `MODULE.bazel`, so a host with no compiler installed can still build:

```starlark
bazel_dep(name = "hermetic_cc_toolchain", version = "4.3.0")

zig = use_extension("@hermetic_cc_toolchain//toolchain:ext.bzl", "toolchains")
use_repo(zig, "zig_sdk")

register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.28",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.28",
)
```

`tbhb_rules_go` can't register it for you: the extension creates `zig_sdk` only for the root module. macOS and Windows keep their local toolchain. `go/e2e/smoke` is a consumer set up this way.

### D2 diagrams

`tbhb_rules_d2` renders [D2](https://d2lang.com) diagrams and keeps the renders committed beside their sources. Each `x.d2` has an `x.d2.svg` (D2's own SVG), an `x.d2.png` (resvg draws the SVG at twice its size in Source Sans Pro and Source Code Pro, and oxipng shrinks the file), and an `x.d2.sha256` (the `shasum -a 256` lines of the three files).

```starlark
load("@tbhb_rules_d2//:defs.bzl", "d2_diagrams")

d2_diagrams(name = "diagrams")
```

By default `d2_diagrams` renders every `*.d2` file in the package and its subdirectories, and `srcs` narrows the set. List the files a diagram reads in `data`: imported `.d2` files (`...@shared`, `x: @x`) and local images, which d2 finds relative to the source. Renders run offline, so a remote image (`icon: https://...`) fails the render. Save the image beside the source and list it in `data` instead. The PNG step fails on any font family in the SVG that it has no font for. `bazel run //docs:diagrams` writes the renders beside their sources and deletes renders that have lost their source. `//docs:diagrams_test` fails when a render is missing, when a committed SVG differs from a fresh render, when a manifest doesn't hold the hashes of the committed files, or when a render has no source. The test doesn't draw the bitmap again, because its pixels can differ across platforms. The manifest vouches for it instead. `:diagrams.renders` builds the renders into the output tree. Keep the renders byte for byte in Git: mark `*.d2.svg` and `*.d2.sha256` `eol=lf` and `*.d2.png` `binary` in `.gitattributes`. Keep fixers away from them too: add `.*\.d2\.(svg|png|sha256)$` to the `exclude` of any pre-commit or prek config with whitespace, line-ending or byte-order-mark fixers. In `.editorconfig`, set `trim_trailing_whitespace = false` for `[*.d2.{svg,png,sha256}]`.

### Ansible

`tbhb_rules_ansible` checks Ansible content in the same scratch tree as the whole-tree checks, with ansible-core, ansible-lint and Molecule from a locked uv environment.

```starlark
ansible = use_extension("@tbhb_rules_ansible//:extensions.bzl", "ansible")
ansible.toolchain(lock = "//ansible:uv.lock", pyproject = "//ansible:pyproject.toml")
ansible.collections(lock = "//ansible:requirements.lock.json", requirements = "//ansible:requirements.yml")
```

Both tags are optional and only the root module may declare them. `toolchain` names a uv project in any package, whose `.python-version` picks the interpreter. Without it, the checks use the module's own pins in `ansible/tools/`: ansible-core 2.22.0, the first release that runs on Python 3.15. Every check also takes `python_env`, such as `@tbhb_python//:env` when the root uv project depends on ansible-core.

`ansible_syntax_check_test` lists the inventory with `ansible-inventory --list` and runs `ansible-playbook --syntax-check` on each playbook. `ansible_lint_test` runs ansible-lint with `--offline` under a watchdog. At 80% of the test timeout (240 s without one), the watchdog prints the process table by name plus the last output lines, then kills ansible-lint and exits 124. Its default config is the production profile plus the opt-in rules, named one by one in `ansible/private/ansible-lint.yml`. An `.ansible-lint` in `srcs`, or `config`, replaces it entirely, and the test log says which config ran. Both tests set `ANSIBLE_CONFIG` to the tree's `ansible.cfg`, put only the pinned collections on `ANSIBLE_COLLECTIONS_PATH`, which overrides any `collections_path` in the config, and keep the Ansible home and temporary directories under `TEST_TMPDIR`. They run on Linux and macOS. ansible-core doesn't run on Windows, so the tests are incompatible there.

`requirements.yml` pins each Galaxy collection with `name`, one exact `version`, and `source: https://galaxy.ansible.com/api/`, and lists every transitive dependency. Without `/api/`, Renovate can't look the collection up. A range is an error. `bazelisk run @tbhb_rules_ansible//:lock` writes `requirements.lock.json` beside it with each collection's URL and sha256, read from Galaxy's metadata. It never downloads a tarball. The extension fetches each tarball by that sha256 and fails on any dependency in a collection's `MANIFEST.json` that the file doesn't pin. `ansible_collections_lock_test` fails when the two files disagree. The extension requires the name `requirements.lock.json` for the lock, the only name that the Renovate post-upgrade task commits. That task runs `bazelisk run @tbhb_rules_ansible//:lock` from the repository root, so it covers an `ansible.collections` tag in the root `MODULE.bazel`. A nested module root, such as `ansible/e2e/` here, reruns the lock by hand.

`molecule_test` runs `molecule test` on a role. It needs Docker and the network, so it's tagged `manual` and runs only when named. Its docstring has the details. `ansible/e2e/` is a consumer with both kinds of environment and the failure proofs.

### Windows

The rules' executables are Bash scripts. On Windows each runs through a `.bat` launcher with the Bash of the shell `toolchain`, so set `BAZEL_SH` to an MSYS2 or Git for Windows `bash.exe`. The scripts read their files from the `runfiles` tree, so add `startup --windows_enable_symlinks` and `common:windows --enable_runfiles` (with `common --enable_platform_specific_config`) to your `.bazelrc`, and turn on Developer Mode so Bazel can create the symlinks.

## Develop

mise provides bazelisk and uv (`mise install`). Bazel pins everything else. `mise run env` (`bazel run //tools:bazel_env`) puts shims for those pins in `tools/.bazel_env/bin`, which the git hooks call and mise adds to PATH.

| Command | Checks |
| --- | --- |
| `bazelisk test //...` | buildifier, this repository's lint, shell and Python gates (in `tools/`), run on its own rules |
| `(cd e2e/smoke && bazelisk test //...)` | the rules as a consumer sees them, including the failure proofs |
| `bazelisk run //:format` | rewrites files with the formatters, and `//:format.check` only checks |
| `(cd go && bazelisk test //...)`, `(cd python && bazelisk test //...)`, `(cd ansible && bazelisk test //...)`, `(cd diagrams/d2 && bazelisk test //...)` | the nested modules, each with its own consumers under `e2e/` |
| `(cd apple/e2e/smoke && bazelisk test //...)` | Swift and Apple builds under `rules_swift` and `rules_apple`. It needs macOS and Xcode, so CI runs it on a GitHub-hosted macOS runner. Its README has the findings |
| `(cd swift/e2e/smoke && bazelisk test //...)` | `tbhb_rules_swift` consumer: a library, an iOS simulator app, a macOS app, and lint, flag, sanitizer and failure-proof gates. Requires macOS with Xcode. See `swift/README.md` for the module and its gates |
| `mise run test` | every command in this table except the format runs and the Apple and Swift smokes |

`.github/workflows/ci.yml` lists the complete gate set.

### Lock cooldown

Maintained pnpm and uv projects, including the E2E consumers, apply the same
five-day cooldown as Renovate version bumps: `minimumReleaseAge: 7200` in
`pnpm-workspace.yaml` and `exclude-newer = "5 days"` in `[tool.uv]`.
Refresh locks with the pinned pnpm (`bazelisk run @pnpm//:pnpm -- --dir "$PWD" install --lockfile-only`)
or uv (`uv lock`). Their pins live in `MODULE.bazel` and `mise.toml`.
The Ansible consumer keeps its older exact `ansible-core` pin to test a
different toolchain, while the cooldown still covers its maintained lock.
Python workspace members inherit the root lock's cooldown. Planted projects
and mutation source-path fixtures have no independent lock to refresh and
keep their deliberate dependency and configuration inputs.
The historical lock in `tools/testdata/lock_cooldown` stays byte-stable.
Renovate skips it so the clock regression retains its original resolution.
Only E2E modules with pnpm or uv locks need these settings.

uv 0.13.7 documents that [advancing time alone doesn't update a relative cooldown lock](https://github.com/astral-sh/uv/blob/0.13.7/docs/concepts/resolution.md#dependency-cooldowns).
Its [lock comparison ignores timestamp changes when the span is unchanged](https://github.com/astral-sh/uv/blob/0.13.7/crates/uv-configuration/src/exclude_newer.rs),
and `uv.lock` stores the duration as `exclude-newer-span = "P5D"`.
`//tools:lock_cooldown_test` checks a fixture locked at 2024-05-01 with
`uv lock --check --offline` and `uv lock --offline` at that date, the next day,
the next month and the next year, comparing the lock bytes after every run.
It uses uv's [own test clock](https://github.com/astral-sh/uv/blob/0.13.7/crates/uv-distribution-types/src/exclude_newer.rs)
(`UV_INTERNAL__TEST_CURRENT_TIMESTAMP`), verifies that uv honors the override,
and proves that changing the span to six days fails `--check`.
