# Shared CI pieces

Repositories using `tbhb_rules` would otherwise each copy the same CI. The shared parts are these:

- `.github/actions/setup-bazel-ci` prepares a Bazel job.
- `.github/actions/ci-conclusion` decides the `conclusion` check.
- `.github/workflows/repo-checks.yml` runs the repository-level checks.
- `.github/workflows/pr-text.yml` scans a pull request's title and body after an edit.

A consumer keeps its own `ci.yml` with the checkout, the test matrix, and the Bazel commands. The pieces cover the steps that never differ between repositories.

## `setup-bazel-ci`

Run it after `checkout`. It runs these steps in order:

1. Harden the runner with `step-security/harden-runner` in audit mode, on Linux only.
2. Point `BAZEL_SH` at MSYS2's Bash, on Windows only, and fail when it's missing from `C:/msys64`.
3. Set up Bazel with `bazel-contrib/setup-bazel` and turn on the bazelisk cache plus the repository cache, trying up to three times with pauses of 60 and 120 seconds, since a GitHub release download can return 504 for minutes.
4. On Linux under a container CPU quota, size the workers to it. The step exports the quota (rounded up, from `cpu.max` or cgroup v1) as `PYTEST_XDIST_AUTO_NUM_WORKERS`, for `-n auto` in a `pytest_test`, and adds `build --local_resources=cpu=N` to `~/.bazelrc`, because Bazel counts the host's CPUs. `mutmut_test` reads the quota itself. Without a quota the step does nothing.
5. On Linux arm64, download a pinned Rust toolchain and zig, check both against pinned hashes, and put them on `PATH` for the source build of complexipy, with `cc`, `c++` and `ar` running zig. A runner image without Rust or a C compiler works too.
6. Shorten Bazel's output root and enable long paths, on Windows only.
7. Read `fetch-targets.txt` beside the action and fetch `//...`, the Bazel subcommand tools (including `buildozer` for `bazel mod tidy`), and each run-only target that the workspace declares. The list covers `gitleaks`, `zizmor`, `gazelle`, `pip-audit`, `pnpm audit`, `govulncheck`, and the tools that scan the title and body of a pull request. `@tbhb_rules//lint:zizmor` resolves `@tbhb_rules_zizmor//:zizmor` through the rules module's repository mapping, including from nested workspaces. Retry with pauses that start at 30 seconds and double. When the next pause would pass `retry-budget-minutes`, the step fails and prints the last URL from the output.

| Input               | Default  | Meaning                                                                                                 |
|---------------------|----------|---------------------------------------------------------------------------------------------------------|
| `disk-cache`        | `false`  | The disk cache key, unique per job, such as `${{ github.workflow }}-${{ matrix.os }}`. `false` is none. |
| `cache-save`        | `false`  | Whether the run saves the caches. Only `cache-warm` passes `true`.                     |
| `targets`           | `@default` | Read `fetch-targets.txt` beside the action. Other values name targets, split on whitespace. Empty skips the fetch.                                        |
| `fetch-workspaces` | empty | Other workspace directories to fetch with the default list, relative to `working-directory`, split on whitespace. |
| `working-directory` | `.`      | The Bazel workspace the fetch runs in.                                                                   |
| `retry-budget-minutes` | `8`   | Whole minutes the fetch may spend retrying, counted from the start of the fetch step. The setup attempts, with their 3 minutes of pauses, are outside it. |

The `fetch-seconds` output counts target selection and fetch time. `//repo/tests:cache_fetch_test` checks workspace selection and failure handling. `//repo/tests:cache_contract_test` checks the run-only tool list, every hash list, the cache writer, and the setup action pin against the lookup key format.

The root `MODULE.bazel`, `MODULE.bazel.lock`, and `pins/*.bzl` determine the repository cache key for every job, including jobs that fetch from nested workspaces. `hashFiles` accepts a `pins/*.bzl` glob when a consumer lacks that directory. The setup attempts use this file list. Disk caches also use these inputs, plus the build files that `setup-bazel` adds.

Only the `cache-warm` job saves caches. It runs on pushes to `main`, across the four test platforms. The exact lookup skips setup and fetch when an archive exists. On a miss, `setup-bazel` restores the newest archive in the shared platform and architecture family before the script fetches the full list. Successful runs save the new key. If the fetch fails, the action discards the incomplete repository cache before the setup action's post step. The job summary reports fetch seconds and repository cache size. Linux and macOS use `~/.cache/bazel-repo`. Windows uses `<output base>-repo`. The lookup uses the same absolute path, because the cache toolkit includes it in the archive version.

Because `checkout` runs first, the hardening starts after it.

## `ci-conclusion`

The action prints the `needs` context and fails unless every result equals `success`, and a skipped, cancelled, or abandoned job fails the check. Hardening the runner is part of it. The calling job needs nothing else.

| Input   | Required | Meaning                                                   |
|---------|----------|-----------------------------------------------------------|
| `needs` | yes      | The `needs` context as JSON: pass `${{ toJSON(needs) }}`. |

### `conclusion` stays a local job

Keep a job named `conclusion` in your own `ci.yml` and call this action from it. The ruleset requires the check context `conclusion`, and a job that calls a reusable workflow reports a different context. Give the job `if: always()` so it runs after a failed job.

## `repo-checks.yml`

The `repo` job clones the full history and makes these checks in order. An empty input skips its check, except for gitleaks, zizmor, and CODEOWNERS, which always run.

1. `bazel run //:gazelle -- -mode=diff` in each of `gazelle-dirs`.
2. `bazel mod tidy` in each of `module-dirs`, then `git diff --exit-code` on their `MODULE.bazel`.
3. `//:gitleaks_history`.
4. On a pull request, `@tbhb_rules//lint:gitleaks_text` on its title and body.
5. `pip-audit-target`.
6. `bazel run //:pnpm_audit -- --dir <dir>` in `pnpm-audit-workspace`, for each of `pnpm-audit-dirs`.
7. `govulncheck-target`, in `govulncheck-working-directory`, and keep the report as an artifact.
8. zizmor, with the online audits, and the pedantic persona.
9. The CODEOWNERS owner and syntax check through the GitHub API, with `curl` and `jq`.

On a pull request and on a push alike, the history scan covers only the tested commit's history, so a finding on another open pull request's branch, which the full clone also holds, fails only that pull request. The title and body get the same rules as the history, the private ones included, because a squash merge makes them the commit message.

| Input                           | Default             | Meaning                                                            |
|---------------------------------|---------------------|--------------------------------------------------------------------|
| `runs-on`                       | `ubuntu-26.04`      | The runner label.                                                  |
| `timeout-minutes`               | `15`                | The job's timeout.                                                 |
| `retry-budget-minutes`          | `8`                 | Whole minutes the gazelle build and `bazel mod tidy` retries may spend, all directories together, counted from the end of the Bazel setup. |
| `pip-audit-target`              | `//tools:pip_audit` | The Python audit target.                                           |
| `pnpm-audit-dirs`               | empty               | Directories with a pnpm lock to audit, split on whitespace.     |
| `pnpm-audit-workspace`          | `.`                 | The workspace that contains `//:pnpm_audit`.                       |
| `govulncheck-target`            | empty               | The govulncheck target.                                            |
| `govulncheck-working-directory` | `.`                 | The workspace that contains the target.                            |
| `gazelle-dirs`                  | empty               | Workspaces where gazelle must leave the Bazel package files alone, split on whitespace. |
| `module-dirs`                   | empty               | Modules whose `MODULE.bazel` must match `bazel mod tidy`, split on whitespace. |

When a retry would pause past the budget, the step fails and prints the last URL from the command's output. A long outage ends in a clear failure. Keep `retry-budget-minutes` below `timeout-minutes`, with time left for the other steps. `//repo/tests:retry_budget_test` checks the defaults.

The calling job must grant `contents: read`, because a called workflow's token can never exceed its caller's.

This workflow sets up Bazel inline and doesn't call `setup-bazel-ci`. A `./` path in a called workflow resolves in the caller's checkout. That checkout lacks the action.

Both reusable workflows set `cache-save: false` and use the same key family as `cache-warm`. After setup, `bazel query --output=location` locates `fetch-targets.txt` in the `tbhb_rules` module that the caller pins in `MODULE.bazel`. The script beside that file fetches the declared run-only tools. The source archive includes both files under `.github/actions/`. The caller's checkout needs only its own sources. Keep the workflow, action, and Bazel module pins on the same rules revision when Renovate updates them.

## `pr-text.yml`

An edit to a pull request's title or body doesn't start a CI run, so `repo-checks.yml` doesn't see it. This workflow runs `@tbhb_rules//lint:gitleaks_text` on the edited text, and because the ruleset doesn't require its check, a red one only marks the edit until the next push scans the text again under `conclusion`. Call it from a workflow of its own:

```yaml
on:
  pull_request:
    types: [edited]

jobs:
  pr-text:
    permissions:
      contents: read
    uses: tbhb-dev/rules/.github/workflows/pr-text.yml@<sha>  # main
    secrets:
      GITLEAKS_CONFIG_TOML: ${{ secrets.GITLEAKS_CONFIG_TOML }}
```

It takes one input, `runs-on`, with the default `ubuntu-26.04`. It reads the same fetch list from the pinned Bazel module and restores caches without saving them.

## In a consumer's `ci.yml`

Adopt the rules pin update from Renovate, then edit the consumer's `ci.yml`: set `cache-save: false` on every test job and add one `cache-warm` job for pushes to `main`. Copy the `cache-warm` job from [this repository's `ci.yml`](../workflows/ci.yml), replace its local action reference with the same pinned remote reference as the test job, and set `fetch-workspaces` to the consumer's other workspace directories. Keep the four OS entries from the test matrix. The warm job hashes the root workspace files even when it fetches tools from another workspace. Keep `cache-warm` outside the required `conclusion` dependencies, because pull requests skip it.

Pin `tbhb-dev/rules` by commit and put the branch in a trailing comment. Renovate updates those action and workflow references along with the Bazel module pin. A rules pin update alone leaves an existing consumer's test jobs as cache writers until the `ci.yml` edit merges. The consumer changes the copied warm job's setup step to:

```yaml
- name: Warm the complete repository cache
  id: warm
  if: steps.cache.outputs.cache-hit != 'true'
  uses: tbhb-dev/rules/.github/actions/setup-bazel-ci@<sha>  # main
  with:
    cache-save: true
    # Omit this input for a single workspace.
    fetch-workspaces: additional-workspace
```

The rest of the consumer's `ci.yml` uses these jobs:

```yaml
jobs:
  bazel:
    name: "bazel (${{ matrix.os }})"
    runs-on: ${{ matrix.os }}
    timeout-minutes: 30
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-26.04, ubuntu-26.04-arm, macos-26, windows-2025]
    defaults:
      run:
        shell: bash
    steps:
      - name: Checkout
        uses: actions/checkout@<sha>  # <version>
        with:
          persist-credentials: false

      - name: Set up Bazel for CI
        uses: tbhb-dev/rules/.github/actions/setup-bazel-ci@<sha>  # main
        with:
          disk-cache: ${{ github.workflow }}-${{ matrix.os }}
          cache-save: false

      - name: Test
        # Only for a repository that sets the private gitleaks config; see
        # the following section.
        env:
          GITLEAKS_CONFIG_TOML: ${{ secrets.GITLEAKS_CONFIG_TOML }}
        run: bazelisk test --config=ci //...

  repo:
    name: repo
    permissions:
      contents: read
    uses: tbhb-dev/rules/.github/workflows/repo-checks.yml@<sha>  # main
    with:
      gazelle-dirs: .
      module-dirs: .
    secrets:
      GITLEAKS_CONFIG_TOML: ${{ secrets.GITLEAKS_CONFIG_TOML }}

  conclusion:
    name: conclusion
    if: always()
    needs: [bazel, repo]
    runs-on: ubuntu-26.04
    timeout-minutes: 5
    steps:
      - name: Fail if any needed job did not succeed
        uses: tbhb-dev/rules/.github/actions/ci-conclusion@<sha>  # main
        with:
          needs: ${{ toJSON(needs) }}
```

### The private gitleaks config

A repository whose `.bazelrc` sets `common --@tbhb_rules//lint:gitleaks_private_config` runs `gitleaks_test` and `gitleaks_history` with a private config from the `GITLEAKS_CONFIG_TOML` environment variable. Begin the private config with `[extend] path = ".gitleaks.toml"` and define a rule with the id `tbhb-private-canary`. Keep only local rules and allowlists in the committed config. Bazel supplies the base from the rules module and redirects the private extension through a temporary effective config. This preserves default rules without the upstream global allowlist within two extension levels. See [gitleaks policy](../../README.md#gitleaks-policy) for migration and regeneration. Both checks fail without the private config. In CI the variable comes from a secret, which the test step sets and the `repo` job passes on to `repo-checks.yml`. A composite action can't read secrets, so `setup-bazel-ci` never sees it. Repositories without the flag leave both lines out.

The consumer's `conclusion` job skips `checkout`: the runner fetches a remote action itself. This repository's own `ci.yml` uses the same jobs with local paths, `./.github/actions/...` after `checkout` and `./.github/workflows/repo-checks.yml`, since a change can't pin its own commit.

Each move of `main` leaves the `# main` comment naming a newer commit until the Renovate bump merges. Because of that, the consumer's `.github/zizmor.yml` ignores two audits for the workflow file with these pins:

```yaml
rules:
  stale-action-refs:
    ignore:
      - ci.yml
  ref-version-mismatch:
    ignore:
      - ci.yml
```
