---
description: Detect changes to review controls in a Git range.
status: stable
tags: [bazel, review, testing]
title: Review control changes
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:a5647b1373d26dea
    at: "2026-11-11T20:17:00Z"
---

# Review control changes

Run the detector from the checkout under review:

```sh
bazelisk run @tbhb_rules//lint:controls_changed -- BASE HEAD
bazelisk run @tbhb_rules//lint:controls_changed -- --json BASE HEAD
```

This flag requests heavier review. Reviewers name the listed paths in their verdict. The detector compares committed trees at `BASE` and `HEAD`, reporting additions, modifications, deletions, and both sides of renames. It exits zero even when it finds controls. Only committed changes enter the report.

## Categories

The rule reads its patterns from [`categories.json`](../../lint/private/controls_changed/categories.json). Each category has a stable name and path expressions, added-line expressions, or a content selector. Paths use forward slashes relative to the checkout root.

| Category | Signals |
| --- | --- |
| `lint-format` | Vale config and local styles, cspell config and word lists, `rumdl`, `ryl`, Ruff, pyrefly, `pylint`, golangci-lint, and Biome config. Changes within Ruff, pyrefly, or `pylint` sections in `pyproject.toml` also count. |
| `ci-workflows` | Files below `.github/workflows/` or `.github/actions/`. |
| `secret-scanning` | `.gitleaks.toml`, `.gitleaksignore`, or an added `gitleaks:allow` directive. |
| `coverage-mutation-pragmas` | Added `pragma: no cover`, `pragma: no mutate`, `//nolint`, `# noqa`, `# type: ignore`, or `eslint-disable`. Repository conventions also include pyrefly, Bandit, shellcheck, `yamllint`, buildifier, and zizmor suppressions, `gomutants:disable`, `Stryker disable`, and Istanbul, c8, or v8 ignore directives. |
| `hooks` | `.pre-commit-config.yaml` or any directory whose name ends in `hooks`, including `.githooks`. |
| `ownership-review` | Root, `.github/`, or `docs/` CODEOWNERS, `.github/pull-request-sections.toml`, `.github/settings.yml` or `.yaml`, and `.github/ruleset` or `rulesets` files and directories. |
| `test-lists` | Removed test targets, removed `srcs` entries, or removed test-suite members in `BUILD` or `BUILD.bazel`. |

Vale's synced `Google`, `write-good`, `proselint`, `ai-tells`, and `ai-tells-experimental` package directories are outside the local-style category. Other local styles and vocabulary files count. The cspell word lists use names or directories beginning with `.cspell` or `cspell`.

Directive matching checks added lines, including replacement lines. An unchanged directive in diff context or a removed directive doesn't count. Matching is lexical, so a new example or quoted directive can also warrant review.

Test-list detection reads direct calls whose names end in `_test`, plus `test` and `test_suite`, including calls through `native`, without executing `BUILD` code. It compares literal target names and the literals, names, and attribute references in their `srcs` and `tests` expressions, following references to top-level constants. Reordering sources or adding a source doesn't count. It doesn't expand custom macros or run `glob` expressions. Changed `BUILD` syntax that the parser can't read flags `test-lists` conservatively.

## Output

Each matching path occupies one line in the default output, in sorted order. Path lines contain a JSON-quoted path, a tab, and sorted category names separated by commas. Quoting keeps unusual paths intact. Counts of matching paths and distinct categories follow:

```text
".gitleaks.toml"	secret-scanning
controls_changed: 1 paths, 1 categories
```

`--json` emits one object with these fields:

- `files`: sorted entries, each with a `path` and a sorted list of `categories`.
- `categories`: sorted names of all categories with a hit.
- `error`: `null` on success, or a message explaining why detection couldn't run.

Empty ranges return empty lists. Git or category-read errors also return empty lists, with an error message and exit zero, so consumers must inspect `error` before treating an empty list as a clean report. Invalid command-line arguments produce a usage error.

`--github` adds a **Review controls changed** section to `GITHUB_STEP_SUMMARY` and emits one warning annotation per distinct category, naming its matching paths. Escaping protects the summary and annotations from unusual paths. For pull requests, the reusable `repo-checks.yml` workflow runs this mode using the event's base and head commits. Build and execution failures never fail the job.

## Tests

`bazelisk test //tools:controls_changed_test` creates a throwaway Git repository with one commit per category and an ordinary source commit that doesn't produce a hit. Exact-output checks cover text, JSON, summaries, and annotations. The tests also cover unchanged and removed directives, config sections, synced Vale styles, removed test targets and sources, renames, deletions, dirty working trees, error reports, and the workflow's range and tolerance of errors. Python branch coverage must reach 100%.
