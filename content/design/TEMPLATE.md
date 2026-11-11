---
type: Design Draft
title: Design title
description: A skeleton for a design README and its appendices.
tags: [design, content]
status: draft
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:fb2bbc10b42a2d56
    at: "2026-11-11T18:31:51Z"
---

# Design title

| Status | Owner | Updated | Needs from tbhb |
| --- | --- | --- | --- |
| Draft | Durable role | YYYY-MM-DD | One decision, about five minutes |

## Summary

Describe the problem, the proposal and what changes for tbhb in at most 150 words and three short paragraphs. State the recommendation so a reader who stops here understands the design.

## Decisions for tbhb

Keep only decisions about an irreversible change, a credential or grant, a wider trust boundary, or tbhb's standing rules. Put reversible implementation choices under Already decided. If no decisions remain, replace the D items with “None.” and keep this heading.

### D1. What needs a decision?

- **Recommendation:** State one answer.
- **Why:** Give the reason in one or two sentences.
- **If yes:** Say what happens next.
- **If no:** Name the alternative and its cost.
- **Reversible:** Say whether the decision can be reversed, and how or why.

Repeat for each decision. Each question must be answerable in one line, such as “D1: yes”.

## Already decided

- State the decision, its durable owner and a citation to the operator's decision records.

## Proposal

Describe what will exist, who runs each component and what each component owns. Keep this section to about one page and leave mechanics to How it works.

## How it works

Explain the mechanics needed to assess the proposal. Use steps, tables or a diagram where useful; move details longer than about two pages to an appendix.

## Risks and unknowns

| Risk or unknown | Effect if it goes wrong | What handles it | Evidence |
| --- | --- | --- | --- |
| Name the uncertainty | Describe the effect | Name the mitigation or first build that settles it | unverified: source needed |

## Plan

| Step | What lands | Done when | Owner |
| --- | --- | --- | --- |
| 1 | First deliverable | A check anyone can run | Durable role |

Exercise unknowns in the first build that depends on them. No step waits for a hands-on sitting that only confirms documented behavior.

## Appendices

Create one file per topic and replace these examples with links to real files:

- `A-evidence.md`: evidence, source citations and the proven, existing, new or unverified labels.
- `B-alternatives.md`: alternatives and why they were declined.

Remove this section if there are no appendices.

<!-- Copy the skeleton above into README.md. Replace its frontmatter with the
complete example below and remove this comment and the instructions below. -->

## Preparing the files

The template's own frontmatter uses today's shared schema. A copied design uses these additional fields, which the design checker validates independently:

```yaml
type: Design Draft
title: Design title
description: What this designs and for whom.
tags: [design]
status: draft
owner: Durable role
updated: "2026-11-11"
decisions_open: 1
```

Use `draft`, `decided` or `superseded` for status and keep the count synchronized with the D headings. Keep the title to eight words or fewer. The README should stay within about 250 lines.

Each appendix is named `[A-Z]-<kebab>.md`, starts with `type: Design Appendix` and `parent: README.md` frontmatter, and links back with `[Design](README.md)`. The README links every appendix. Review [the writing checklist](WRITING.md) before asking for [review](REVIEW.md).
