# Agent instructions

Before choosing a model for a subagent or peer run, read models/README.md in tbhb-dev/wiki (<https://github.com/tbhb-dev/wiki/blob/main/models/README.md>).

## Tier 2 review paths

Determine the tier before review from the paths the diff touches and the scope in the table. Tier 1 is the default. Class 2 protects the agent account boundary. Class 3 applies when a change loosens merge-gate enforcement. A reviewer can raise the tier. Every later decision must honor the highest tier.

Tier 2 requires two fresh review runs with different variants. Each run must use a provider other than the builder's. This repository has no class 1 paths for durable data deletion.

| Glob | Class | Reason |
| --- | --- | --- |
| `.claude/settings.json` | 2 | The deny and account boundary settings restrict direct pull request actions. |
| `repo/baseline/files/.claude/settings.json` | 2 | The baseline deny and account boundary settings set those restrictions for new repositories. |
| `.codex/rules/pull-request.rules` | 2 | Blocks agents from using direct pull request creation, editing, and merge commands. |
| `lint/private/claude_settings/check_claude_settings.py` | 2 | The deny check requires the direct pull request restrictions. |
| `.github/CODEOWNERS` | 2 | Sets who GitHub treats as code owners for review requests and approvals. |
| `repo/baseline/files/.github/CODEOWNERS` | 2 | Sets the policy on code ownership for new repositories. |
| `.github/workflows/renovate-auto-approval.yml` | 2 | Sets when automation can approve a dependency pull request. |
| `repo/private/renovate_approval/**` | 2 | Checks whether automation may approve a dependency pull request. |
| `.github/rulesets/**` | 3 | Sets branch protection, approval requirements, and required checks. |
| `repo/baseline/files/.github/rulesets/**` | 3 | Sets how new repositories protect branches and govern merges. |
| `.github/workflows/ci.yml` | 3 | Selects which jobs the required conclusion checks. |
| `repo/baseline/seed/*/.github/workflows/ci.yml` | 3 | Sets the default required conclusion and its dependencies. |
| `.github/actions/ci-conclusion/action.yml` | 3 | Requires every job in the conclusion's dependency list to succeed. |
| `.github/workflows/repo-checks.yml` | 3 | Runs repository checks under the required conclusion. |
| `lint/repo_checks.toml` | 3 | Selects the repository checks and their argument forms. |
| `lint/repo_checks.py` | 3 | Runs the selected checks and propagates failures. |
| `lint/pr_merge_base.sh` | 3 | Resolves the base commit for checks on a pull request's commit range. |
| `lint/private/required_status_checks.bzl` | 3 | Wires the required status check to the ruleset and workflow. |
| `lint/private/required_status_checks/check_status_checks.py` | 3 | Verifies required status checks and the conclusion's dependencies. |
| `lint/private/review_policy.bzl` | 3 | Wires the check for the review policy floor to the repository's policy files. |
| `lint/private/review_policy/check_review_policy.py` | 3 | Fails the gate when the review policy is weaker than the floor. |
| `.github/pr-size-exempt.txt` | 3 | Exempts repository paths from the size gate for pull requests. |
| `lint/private/pr-size-exempt.txt` | 3 | Defines shared exemptions from the size gate for pull requests. |
| `lint/private/pr_size*.sh.tpl` | 3 | Counts changed lines and enforces size limits for pull requests. |
| `BUILD.bazel` | 3 | The required status and review policy target wiring selects what those checks inspect. |
| `lint/BUILD.bazel` | 3 | The repository check and review policy target wiring selects the gate code and inputs. |

A behavior-preserving refactor within a listed scope still requires tier 2 even when tests prove equivalence unless @tbhb records an exception before tier assignment.

## Tests that run a subprocess

Windows legs run only on pushes to main. A failure there shows only after the merge, on main. Give every new test that runs a subprocess the Windows exclusion in the same pull request, unless the test targets Windows:

```starlark
target_compatible_with = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
}),
```

Add a tech-debt comment on the line before it, and a tracker row. A reviewer checks for the exclusion on any new test that shells out, and reports a missing one as blocking.
