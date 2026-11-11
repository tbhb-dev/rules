---
description: Allowed commit identities and required agent identity trailers.
status: stable
tags: [bazel, lint]
title: Commit identity
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:c5904b7f27d4f212
    at: "2026-11-11T17:29:13Z"
---

# Commit identity

Run `bazel run @tbhb_rules//lint:commit_identity -- BASE HEAD` from a consumer workspace. It checks every commit in `BASE..HEAD` against `ALLOWED_PAIRS` in `lint/private/commit_identity.bzl`. The author and committer together must match an allowed pair. `repo-checks.yml` runs the target on a pull request's base and head.

## Agent messages

Either email can trigger trailer validation: `agent@tonyburns.net` as author or committer.

The full message must contain at least one `Generated-by:` or `Assisted-by:` line. These keys are case sensitive and start at the beginning of a line. Every matched value must follow the grammar below, and every `Generated-by` line must precede every `Assisted-by` line. The checker accepts repeated lines with the same key. Agent commits also forbid `Signed-off-by` and `Co-authored-by` lines, regardless of case. Their keys can have spaces or tabs before the colon.

Other identities receive only the allowed-pair check.

```text
Generated-by: LLM effort=high;harness=codex;model=openai:m;session=sha-256-64:0123456789abcdef;surface=cli
Assisted-by: LLM harness=claude-code:2.1;model=anthropic:m
```

## Value grammar

A value starts with the literal token `LLM` and contains exactly one whitespace-delimited attribute blob containing `=`. Other tokens may contain prose. Semicolons separate attributes within the blob, with no whitespace. An attribute splits at its first `=`. Its value must be nonempty and contain no whitespace, semicolon, or comma. Values can contain more equals signs.

Attributes appear once each, in the order below. Unknown attributes fail. Model and surface have no constraints beyond the attribute syntax.

| Attribute | Constraint |
| --- | --- |
| `effort` | Optional. One of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. |
| `harness` | Required. Before its first colon, the value must be `claude-code`, `codex`, or `antigravity`. A version suffix is optional. |
| `model` | Required. Identifies the model. |
| `session` | Optional. `sha-256-64:` followed by exactly 16 lowercase hexadecimal digits. |
| `subagent` | Optional. The same hash format as `session`. |
| `surface` | Optional. Identifies the interface. |

## Output

Each problem prints `commit_identity: FAIL: <full sha> <problem>`. The summary counts failing commits, even when a commit has more than one problem. The target exits with status 1 if any commit fails, or prints the number checked and exits with status 0 when all pass.

Both revisions must name commits available in the clone. Invocation without exactly two revisions exits with status 2.
