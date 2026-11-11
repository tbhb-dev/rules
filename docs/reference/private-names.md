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
    session: sha-256-64:bf4e75db256939ba
    at: "2026-11-11T20:18:56Z"
---

# Private repository names

The shared `repo-checks.yml` workflow checks every commit in a pull request's `BASE..HEAD` range, including merges. It checks the full message and each line the commit adds. Removed lines and diff headers are outside the check. Merge diffs compare against the first parent, including resolution changes. A second invocation checks the pull request's title and body through stdin. Both steps run on `pull_request`, after the commit identity check.

Callers set the optional `PRIVATE_NAMES` secret and pass it to the reusable workflow, either explicitly under `secrets: PRIVATE_NAMES` or with `secrets: inherit`. Its value is a newline- or comma-separated list of repository names. Without it only the suffix rule runs. The checker never prints the configured list. A diagnostic prints the token it found in the checked text.

## Token grammar

A token is a run of ASCII letters, digits, `_` and `-`, joined by single dots. The matcher uses `(?<![\w.-])[\w-]+(?:\.[\w-]+)*(?![\w-])` with `re.ASCII`. A preceding letter, digit, underscore, hyphen or dot prevents a new token from starting there. Letters, digits, underscores and hyphens continue a token; single dots join its parts. A final punctuation dot is outside the match, as specified by the regex.

Matching ignores case and a trailing `.git`. A token is private when it ends in `-private` and doesn't start with `-`, or when it equals a configured name. The token `-private` alone doesn't satisfy the suffix rule. Configured names use the same case and `.git` normalization.

Each line produces one problem per distinct private token, after normalization. The problem is `'<token>' names a private repository; describe it generically instead`. Repeated tokens on different lines each produce a problem.

## Run the checker

The target uses rules' pinned Python interpreter and runs in the caller's checkout:

```sh
bazelisk run @tbhb_rules//lint:private_names -- BASE HEAD
printf '%s\n\n%s\n' "$PR_TITLE" "$PR_BODY" |
  bazelisk run @tbhb_rules//lint:private_names -- --text
```

Set `PRIVATE_NAMES` in the environment for a local run. Each commit diagnostic starts with `private_names: FAIL:`, the full commit hash, and either `message` or `path:line`. Text diagnostics use `text`. The checker prints a summary and exits 1 on a hit; a clean range prints its commit count and exits 0. An unreadable repository or invalid revision fails.

If the running repository's `origin` name satisfies the private-name rule, the checker prints `private_names: skipped private repository` and exits 0. This applies to both range and text mode. A repository without an origin still gets checked.

## Fixture exclusions

`PRIVATE_NAMES_EXCLUDE` accepts newline- or comma-separated path globs, relative to the repository root. Matching uses case-sensitive Python `fnmatch` semantics: `*` can match `/`. Matching paths' added lines are excluded; commit messages and stdin remain checked. For example, `PRIVATE_NAMES_EXCLUDE='testdata/*'` allows fixture content under that path. For workflow runs, set the repository configuration variable `PRIVATE_NAMES_EXCLUDE`; for local runs, set the environment variable. This repository's tests construct example tokens at runtime, so their source passes without exclusions.
