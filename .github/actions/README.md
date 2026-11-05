# Shared CI pieces

Repositories using `tbhb_rules` would otherwise each copy the same CI. The shared parts are these:

- `.github/actions/setup-bazel-ci` prepares a Bazel job.
- `.github/actions/ci-conclusion` decides the `conclusion` check.
- `.github/workflows/repo-checks.yml` runs the repository-level checks.

A consumer keeps its own `ci.yml` with the checkout, the test matrix, and the Bazel commands. The pieces cover the steps that never differ between repositories.

## `setup-bazel-ci`

Run it after `checkout`. It runs these steps in order:

1. Harden the runner with `step-security/harden-runner` in audit mode, on Linux only.
2. Point `BAZEL_SH` at MSYS2's Bash, on Windows only.
3. Set up Bazel with `bazel-contrib/setup-bazel` and turn on the bazelisk cache plus the repository cache.
4. Install a Rust toolchain on Linux arm64, for the source build of complexipy. The Python environment rule passes `RUSTUP_HOME` and `CARGO_HOME` through to uv, which leaves `.bazelrc.user` alone.
5. Shorten Bazel's output root and enable long paths, on Windows only.
6. Fetch the targets, retrying up to three times a minute apart.

| Input               | Default  | Meaning                                                                                                 |
|---------------------|----------|---------------------------------------------------------------------------------------------------------|
| `disk-cache`        | `false`  | The disk cache key, unique per job, such as `${{ github.workflow }}-${{ matrix.os }}`. `false` is none. |
| `cache-save`        | `false`  | Whether the run saves the caches. Pass `${{ github.event_name != 'pull_request' }}`.                     |
| `rust-version`      | `1.99.1` | The toolchain installed on Linux arm64.                                                                  |
| `targets`           | `//...`  | The targets to fetch, split on whitespace. Empty skips the fetch.                                        |
| `working-directory` | `.`      | The Bazel workspace the fetch runs in.                                                                   |

Because `checkout` runs first, the hardening starts after it, and the checkout itself goes unobserved.

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
4. `pip-audit-target`.
5. `bazel run //:pnpm_audit -- --dir <dir>` in `pnpm-audit-workspace`, for each of `pnpm-audit-dirs`.
6. `govulncheck-target`, in `govulncheck-working-directory`, and keep the report as an artifact.
7. zizmor, with the online audits, and the pedantic persona.
8. The CODEOWNERS owner and syntax check through the GitHub API.

| Input                           | Default             | Meaning                                                            |
|---------------------------------|---------------------|--------------------------------------------------------------------|
| `runs-on`                       | `ubuntu-26.04`      | The runner label.                                                  |
| `timeout-minutes`               | `15`                | The job's timeout.                                                 |
| `pip-audit-target`              | `//tools:pip_audit` | The Python audit target.                                           |
| `pnpm-audit-dirs`               | empty               | Directories with a pnpm lock to audit, split on whitespace.     |
| `pnpm-audit-workspace`          | `.`                 | The workspace that contains `//:pnpm_audit`.                       |
| `govulncheck-target`            | empty               | The govulncheck target.                                            |
| `govulncheck-working-directory` | `.`                 | The workspace that contains the target.                            |
| `gazelle-dirs`                  | empty               | Workspaces where gazelle must leave the Bazel package files alone, split on whitespace. |
| `module-dirs`                   | empty               | Modules whose `MODULE.bazel` must match `bazel mod tidy`, split on whitespace. |

The calling job must grant `contents: read`, because a called workflow's token can never exceed its caller's.

This workflow sets up Bazel inline and doesn't call `setup-bazel-ci`. A `./` path in a called workflow resolves in the caller's checkout. That checkout lacks the action.

## In a consumer's `ci.yml`

Pin `tbhb-dev/rules` by commit and put the branch in a trailing comment, as the other first-party callers do. The `bazel` job stands for the consumer's test jobs. Copy it, change it, or replace it.

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
          cache-save: ${{ github.event_name != 'pull_request' }}

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

A repository whose `.bazelrc` sets `common --@tbhb_rules//lint:gitleaks_private_config` runs `gitleaks_test` and `gitleaks_history` with a private config from the `GITLEAKS_CONFIG_TOML` environment variable. The config begins with `[extend] path = ".gitleaks.toml"` and defines a rule with the id `tbhb-private-canary`. Both checks fail without it. In CI the variable comes from a secret, which the test step sets and the `repo` job passes on to `repo-checks.yml`. A composite action can't read secrets, so `setup-bazel-ci` never sees it. Repositories without the flag leave both lines out.

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
