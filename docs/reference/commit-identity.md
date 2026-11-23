---
description: Allowed commit identities and required agent identity trailers.
status: stable
tags: [bazel, lint]
title: Commit identity
type: Reference
generated:
  - role: generated
    harness: codex:0.171.0
    model: openai:gpt-6.2-sol
    effort: high
    surface: exec
    session: sha-256-64:92305effc45e4135
    at: "2026-11-23T07:13:10Z"
---

# Commit identity

Run `bazel run @tbhb_rules//lint:commit_identity -- BASE HEAD [HEAD_BRANCH]` from a consumer workspace. It skips merge commits and checks the rest of `BASE..HEAD` against `ALLOWED_PAIRS` in `lint/private/commit_identity.bzl`. The author and committer together must match an allowed pair. `repo-checks.yml` passes the base and head commits and the head branch of each pull request to the target.

## Agent messages

A commit with `agent@tonyburns.net` as author or committer requires agent trailers. If the caller supplies a head branch, the same commit also requires the branch to start with `agent/`.

| Trailer | Agent's contribution |
| --- | --- |
| `Generated-by` | Wrote the content. |
| `Assisted-by` | Took part without writing the content. |
| `Merged-by` | Performed the merge. |

An agent message must contain at least one `Generated-by` or `Assisted-by` line. All three keys are case sensitive and start at the beginning of a line. Every `Generated-by` line must precede every `Assisted-by` line. `Merged-by` is valid only on merge commits and must follow every `Generated-by` and `Assisted-by` line. The checker accepts repeated lines with the same key. Agent commits also forbid `Signed-off-by` and `Co-authored-by` lines, regardless of case. Their keys can have spaces or tabs before the colon.

Other identities receive only the allowed-pair check.

An agent merge message can end with these trailers.

```text
Generated-by: LLM effort=high;harness=codex;model=openai:m;session=sha-256-64:0123456789abcdef;surface=cli
Assisted-by: LLM harness=claude-code:2.1;model=anthropic:m
Merged-by: LLM harness=codex;model=openai:m
```

## Value grammar

The same value grammar applies to `Generated-by`, `Assisted-by`, and `Merged-by`. A value starts with the literal token `LLM` and contains exactly one whitespace-delimited attribute blob containing `=`. Other tokens may contain prose. Semicolons separate attributes within the blob, with no whitespace. An attribute splits at its first `=`. Its value must be nonempty and contain no whitespace, semicolon, or comma. Values can contain more equals signs.

Attributes appear once each, in the order below. Unknown attributes fail. Model and surface have no constraints beyond the attribute syntax.

| Attribute | Constraint |
| --- | --- |
| `effort` | Optional. One of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`. |
| `harness` | Required. Before its first colon, the value must be `claude-code`, `codex`, or `antigravity`. A version suffix is optional. |
| `launch` | Optional. Hash of the launch identifier. |
| `model` | Required. Identifies the model. |
| `session` | Optional. `sha-256-64:` followed by exactly 16 lowercase hexadecimal digits. |
| `started_at` | Optional. Launch timestamp. |
| `subagent` | Optional. The same hash format as `session`. |
| `surface` | Optional. Identifies the interface. |

Attribute names must match `[a-z_]+`. `launch` must use the `session` hash format. `started_at` must be a real Coordinated Universal Time (UTC) instant in exactly `YYYY-MM-DDTHH:MM:SSZ` format, with uppercase `T` and `Z` and whole seconds. It must be at most 300 seconds after the committer date. Earlier times have no age limit. Without a committer date, the checker validates only the timestamp format and instant.

The committer date comes from `git log --format=%ct`, which the committing agent can set with `GIT_COMMITTER_DATE`. The bound checks consistency between self-reported timestamps and doesn't prove when the agent made the commit.

## Output

Each problem prints `commit_identity: FAIL: <full sha> <problem>`. The summary counts failing commits, even when a commit has more than one problem. The target exits with status 1 if any commit fails, or prints the number checked and exits with status 0 when all pass.

Both revisions must name commits available in the clone. The command accepts two or three arguments and exits with status 2 for other argument counts.
