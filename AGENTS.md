# Agent instructions

Before choosing a model for a subagent or peer run, read models/README.md in tbhb-dev/wiki (<https://github.com/tbhb-dev/wiki/blob/main/models/README.md>).

## Tier 2 review paths

Determine the tier before review using the table. Tier 1 is the default. Class 2 protects the agent account boundary. Touching a listed path within its stated scope sets the class shown in the table and requires tier 2. A reviewer can raise the tier. Every later decision must honor the highest tier.

Tier 2 requires two fresh review runs with different variants. Each run must use a provider other than the builder's. This repository has no class 1 paths for durable data deletion.

| Glob | Class | Reason |
| --- | --- | --- |
| `.claude/settings.json` | 2 | The deny and account boundary settings restrict direct pull request actions. |
| `repo/baseline/files/.claude/settings.json` | 2 | The baseline deny and account boundary settings set those restrictions for new repositories. |
| `.codex/rules/pull-request.rules` | 2 | Blocks agents from using direct pull request creation, editing, and merge commands. |
| `lint/private/claude_settings.bzl` | 2 | Selects the deny check and the settings it inspects. |
| `lint/private/claude_settings/BUILD.bazel` | 2 | Exports the code that checks the direct pull request restrictions. |
| `lint/private/claude_settings/check_claude_settings.py` | 2 | The deny check requires the direct pull request restrictions. |
| `lint/private/commit_identity.bzl` | 2 | Defines allowed author and committer pairs and selects the identity checker. |
| `lint/private/commit_identity.sh.tpl` | 2 | Checks identities and invokes trailer validation over the pull request's commits. |
| `lint/private/commit_identity/**` | 2 | Checks the trailers required for agent commits and tests that validation. |
| `.github/CODEOWNERS` | 3 | Sets who GitHub treats as code owners for review requests and approvals. |
| `repo/baseline/files/.github/CODEOWNERS` | 3 | Sets the policy on code ownership for new repositories. |
| `.github/workflows/renovate.yaml` | 2 | Selects the workflow that uses the Renovate app credentials. |
| `repo/baseline/files/.github/workflows/renovate.yaml` | 2 | Sets which workflow uses the Renovate app credentials in new repositories. |
| `.github/renovate.json5` | 2 | Selects the presets and rules for the Renovate app's pull requests. |
| `repo/baseline/seed/*/.github/renovate.json5` | 2 | Sets those presets and rules for new repositories. |
| `.github/workflows/renovate-auto-approval.yml` | 2 | Sets when automation can approve a dependency pull request. Not yet present. |
| `repo/private/renovate_approval/**` | 2 | Checks whether automation may approve a dependency pull request. Not yet present. |
| `AGENTS.md` | 3 | Applies to any text that sets, overrides, or adds exceptions to the rules for assigning the review tier. |
| `CLAUDE.md` | 3 | Applies to any text that sets, overrides, or adds exceptions to the rules for assigning the review tier. |
| `.github/rulesets/**` | 3 | Sets branch protection, approval requirements, and required checks. |
| `repo/baseline/files/.github/rulesets/**` | 3 | Sets how new repositories protect branches and govern merges. |
| `.github/workflows/ci.yml` | 3 | Selects which jobs the required conclusion checks. |
| `repo/baseline/seed/*/.github/workflows/ci.yml` | 3 | Sets the default required conclusion and its dependencies. |
| `.github/actions/ci-conclusion/action.yml` | 3 | Requires every job in the conclusion's dependency list to succeed. |
| `.github/actions/setup-bazel-ci/test.sh` | 3 | Selects and runs the Bazel tests in CI and propagates failures. |
| `.github/workflows/repo-checks.yml` | 3 | Runs repository checks under the required conclusion. |
| `lint/repo_checks.toml` | 3 | Selects the repository checks and their argument forms. |
| `lint/repo_checks.py` | 3 | Runs the selected checks and propagates failures. |
| `lint/repo_check_targets.bzl` | 3 | Generates the target list the repository check uses to detect drift. |
| `lint/pr_merge_base.sh` | 3 | Resolves the base commit for checks on a pull request's commit range. |
| `lint/private/tree_check.bzl` | 3 | Prepares the input tree and runs the selected checker. |
| `lint/private/required_status_checks.bzl` | 3 | Wires the required status check to the ruleset and workflow. |
| `lint/private/required_status_checks/BUILD.bazel` | 3 | Exports the code and inputs for the required status check. |
| `lint/private/required_status_checks/check_status_checks.py` | 3 | Verifies required status checks and the conclusion's dependencies. |
| `MODULE.bazel` | 3 | Applies to the `tbhb_rules_tbhbdev_src` `http_archive` block, which pins the source of the review policy floor. |
| `runtime/review_policy/**` | 3 | Defines the runtime and dependencies for the review policy check. |
| `lint/private/review_policy.bzl` | 3 | Wires the check for the review policy floor to the repository's policy files. |
| `lint/private/review_policy/BUILD.bazel` | 3 | Exports the checker that enforces the review policy floor. |
| `lint/private/review_policy/check_review_policy.py` | 3 | Fails the gate when the review policy is weaker than the floor. |
| `.github/pull_request_review.*` | 3 | Sets the repository's review policy. Not yet present. |
| `.github/PULL_REQUEST_REVIEW_*.md` | 3 | Supplies review templates and checklists that the policy check reads. Not yet present. |
| `.github/schemas/pull-request-review-draft.*` | 3 | Defines the review draft schema that the policy check reads. Not yet present. |
| `.github/pr-size-exempt.txt` | 3 | Exempts repository paths from the size gate for pull requests. Not yet present. |
| `lint/private/pr-size-exempt.txt` | 3 | Defines shared exemptions from the size gate for pull requests. |
| `lint/private/pr_size.bzl` | 3 | Wires the size gate to its runner and exemption inputs. |
| `lint/private/pr_size*.sh.tpl` | 3 | Counts changed lines and enforces size limits for pull requests. |
| `BUILD.bazel` | 3 | The required status and review policy target wiring selects what those checks inspect. |
| `lint/BUILD.bazel` | 3 | The repository check and review policy target wiring selects the gate code and inputs. |

A behavior-preserving refactor within a listed scope still requires tier 2 even when tests prove equivalence unless @tbhb records an exception in the pull request description before tier assignment.

## Tests that run a subprocess

Windows legs run only on pushes to main. A failure there shows only after the merge, on main. Give every new test that runs a subprocess the Windows exclusion in the same pull request, unless the test targets Windows:

```starlark
target_compatible_with = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
}),
```

Add a tech-debt comment on the line before it, and a tracker row. A reviewer checks for the exclusion on any new test that shells out, and reports a missing one as blocking.
