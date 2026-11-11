---
description: Checking pull request commits and text for private repository names.
status: stable
tags: [bazel, lint, security]
title: Private repository names
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:175bf24d1c155640
    at: "2026-11-11T20:29:31Z"
---

# Private repository names

The shared `repo-checks.yml` workflow checks every commit in a pull request's `BASE..HEAD` range, including merges. It checks the full message and each line the commit adds. Removed lines and diff headers are outside the check. Merge diffs compare against the first parent, including resolution changes. A second invocation checks the pull request's title and body through stdin. Both steps run on `pull_request`, after the commit identity check.

Callers set the optional `PRIVATE_NAMES` secret and pass it to the reusable workflow, either explicitly under `secrets: PRIVATE_NAMES` or with `secrets: inherit`. Its value is a newline- or comma-separated list of repository names. Without it only the suffix rule runs. The checker never prints the configured list. A diagnostic prints the token it found in the checked text.

## Token grammar

Tokens contain letters and digits from the American Standard Code for Information Interchange (ASCII), plus `_` and `-`, with single dots joining their parts. Matching uses the regular expression `(?<![\w.-])[\w-]+(?:\.[\w-]+)*(?![\w-])` with `re.ASCII`. Preceding letters, digits, `_`, `-` or dots prevent a new token from starting there. Final punctuation dots fall outside the match.

Matching ignores case and a trailing `.git`. A token is private when it ends in `-private` and doesn't start with `-`, or when it equals a configured name. By itself, `-private` doesn't match the suffix rule. Configured names use the same case and `.git` normalization.

Each line produces one problem per distinct private token, after normalization. Diagnostics use `'<token>' names a private repository; describe it generically instead`. Repeated tokens on different lines each produce a problem.

## Run the checker

The target uses rules' pinned Python interpreter and runs in the caller's checkout:

```sh
bazelisk run @tbhb_rules//lint:private_names -- BASE HEAD
printf '%s\n\n%s\n' "$PR_TITLE" "$PR_BODY" |
  bazelisk run @tbhb_rules//lint:private_names -- --text
```

Set `PRIVATE_NAMES` in the environment for a local run. Each commit diagnostic starts with `private_names: FAIL:`, the full commit hash, and either `message` or `path:line`. Text diagnostics use `text`. A hit causes the checker to print a summary and exit 1. For a clean range, it prints the commit count and exits 0. An unreadable repository or invalid revision fails.

If the running repository's `origin` name satisfies the private-name rule, the checker prints `private_names: skipped private repository` and exits 0. This applies to both range and text mode. Repositories without an origin still undergo the check.

## Fixture exclusions

`PRIVATE_NAMES_EXCLUDE` accepts newline- or comma-separated path globs, relative to the repository root. Python's case-sensitive `fnmatch` rules apply, and `*` can match `/`. The checker skips added lines in matching paths. It still checks commit messages and stdin. To allow fixture content under `testdata/`, set `PRIVATE_NAMES_EXCLUDE='testdata/*'` in the repository configuration variable for workflow runs or in the environment for local runs. At runtime, this repository's tests construct tokens from separate parts and pass without exclusions.
