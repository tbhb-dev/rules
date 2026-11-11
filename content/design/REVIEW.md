---
type: Reference
title: Design review checklist
description: How an independent reviewer checks a design before presenting it to tbhb.
tags: [design, content]
status: stable
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:fb2bbc10b42a2d56
    at: "2026-11-11T19:02:26Z"
---

# Design review checklist

The reviewer has neither written nor edited the design. Read the entire directory, including every appendix, and verify files and primary sources independently of the writer's summary. Present a design to tbhb after a review with zero blocking findings at the exact commit reviewed.

## Blocking structure checks

- [ ] Required frontmatter includes `type`, `title`, `description`, `tags`, `status`, `owner`, `updated`, and `decisions_open`. The count equals the D headings under Decisions for tbhb.
- [ ] The status table comes first, followed by Summary and Decisions for tbhb, then Already decided, Proposal, How it works, Risks and unknowns, Plan and, when needed, Appendices.
- [ ] The Summary has at most 150 words and conveys the proposal and recommendation without requiring further reading.
- [ ] Each D item has Recommendation, Why, If yes, If no and Reversible bullets and is answerable in one line, such as “D1: yes”. Questions for tbhb appear nowhere else.
- [ ] README.md stays within about 250 lines. Detail, history, and evidence belong in appendices.
- [ ] Appendices use `[A-Z]-<kebab>.md` names, `type: Design Appendix`, `parent: README.md` and a link back. The README links every appendix, and all relative links resolve.

## Blocking substance checks

- [ ] Each D item asks tbhb to decide an irreversible choice, approve a credential or grant, widen a trust boundary, or change a standing rule. Reversible choices appear under Already decided with supporting records.
- [ ] Search the operator's decision records for every D item. Move answered questions to Already decided and remove repeated questions.
- [ ] Run outstanding read-only checks and cite their results. Complete available checks before asking for a decision.
- [ ] Open every record cited under Already decided and confirm it supports the claim.
- [ ] Each actor is a durable role or component with an execution environment and a place for its state. Use durable components rather than a long-running coordinating session.
- [ ] Label factual claims proven, existing, new or unverified and cite primary sources in appendix A. Spot-check at least three sources, or all sources if fewer than three exist.
- [ ] Resolve contradictions with the operator's decision records, merged code, and other current designs. Where an older claim remains, identify the authoritative source.
- [ ] Each plan step has a Done when check anyone can run and a durable role as owner. Remove meetings that only confirm documented behavior.
- [ ] Check the operator's standing rules. No unapproved credential disclosure, spending, API keys, per-token billing, authority expansion, weakened stop or weakened review control appears in the proposal.

## Blocking privacy checks

- [ ] A public design contains no private host names, paths, repository names, network details, or other private information.
- [ ] No verbatim tbhb quotes appear.

## Writing checks

- [ ] Paragraphs have at most three sentences. Lists of three or more items use bullets.
- [ ] Define terms at first use and keep their names consistent.
- [ ] Paths use backticks. Use plain words without filler or repeated summaries.
- [ ] For each risk, specify a mitigation or a first build that tests it.

## Report

Use the repository's review channel or review file. Report findings in this format:

```text
Design: <path> at <sha>
Verdict: ready for tbhb | changes needed
Blocking:
- <check>: <file:line>, <problem>, <fix>
Non-blocking:
- <file:line>: <note>
Checked: <decision-record search terms and sources spot-checked>
```

The verdict covers that commit alone. A later commit needs a fresh review of the diff and every checklist item it could affect. The mechanical checks supplement this review. They can't establish the substance of a proposal.
