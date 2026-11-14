---
description: Severity ratings, evidence requirements, and finding ids for review reports.
status: stable
tags: [review, docs]
title: Review severity and finding ids
type: Reference
generated:
  - role: generated
    harness: codex:0.167.2
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:5a62a6ed2fabf767
    at: "2026-11-14T21:54:33Z"
---

# Review severity and finding ids

## Severity

- P1: the change must not merge because the harm is immediate or irreversible if released. Examples include credential or data exposure, data loss, a guard that fails open, a change that breaks main or CI for everyone, and a violation of a Law.
- P2: the author must fix the finding before merge. The defect or gap is recoverable. It causes wrong behavior or bypasses the stated design. Other P2 findings include a missing test for a stated guarantee or a claim in the text that the code or record doesn't support.
- P3: the finding doesn't block merge. It concerns wording, naming, clarity, or small test or doc gaps with no wrong behavior.

## Rating rules

- The reviewer rates a finding that predates the PR by what it can do now, not by when it first entered the code. It blocks this PR when the PR relies on it or changes the same code path. Otherwise, it becomes a tracked follow-up with a named owner. The author and the reviewer record the follow-up where readers can find the PR.
- When reviewers rate the same defect differently, use the higher severity.
- An irreversible effect, such as a fence, a deletion, or a published record, raises the rating one level, capped at P1.
- The reviewer names the exact line or trace for any P1 or P2. Without a named line or trace, the reviewer rates the finding P3 and flags it `unsupported`.
- The report header states which reviewer family found the finding. The family isn't part of the id.

## Numbering findings

- Write an id as `P<severity>-<n>`. Place a hyphen between the severity digit and a plain integer. The id matches `^P[123]-[1-9][0-9]*$`. Exclude letters, dots, and suffixes. The forms `P2a`, `P2-1b`, and `P3.1` are invalid.
- The recorder assigns the integer when it posts the finding. The recorder is whoever relays reviewer reads to the PR or thread. The reviewer sends the severity only, or `P2-?`, and the recorder replaces it with the assigned id.
- The integer counts per PR, per severity, from 1, in the order the recorder first posts a finding, across all reviewers, rounds, and heads. The recorder never reuses or renumbers it.
- A re-rated finding never keeps its id. It takes the next number at the new severity. The recorder marks the old id `re-rated to P<s>-<n>`.
- When reviewers report the same defect separately, the first posted id stands and the others cite it.
- A defect that recurs at a new head keeps its id and cites the head where the reviewer found it.
- In a reply, cite the finding by id plus the head where the reviewer found it: `P2-3 at e42a217c`.
- Re-send a message with a non-conforming id. Don't interpret it.

## Example thread

```text
The recorder: P2-1 at e42a217c: parser.ts:42 accepts an invalid value.
The recorder: P3-1 at e42a217c: guide.md:18 uses an unclear name.
The reviewer: Duplicate of P2-1 at e42a217c: parser.ts:42.
The recorder: P3-1 re-rated to P2-2; guide.md:18 claims an unsupported guarantee.
The author: P2-1 at e42a217c is fixed at f53b328d.
```
