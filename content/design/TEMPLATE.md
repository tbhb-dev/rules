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
    at: "2026-11-11T19:02:26Z"
---

# Design title

| Status | Owner | Updated | Needs from tbhb |
| --- | --- | --- | --- |
| Draft | Durable role | `YYYY-MM-DD` | One decision, about five minutes |

## Summary

Describe the problem, the proposal and what changes for tbhb in at most 150 words and three short paragraphs. State the recommendation so a reader who stops here understands the design.

## Decisions for tbhb

Keep only decisions about an irreversible change, a credential or grant, a wider trust boundary, or tbhb's standing rules. Put reversible choices under Already decided. If no decisions remain, replace the D items with “None.” and keep this heading.

### D1. What needs a decision?

- **Recommendation:** state one answer.
- **Why:** give the reason in one or two sentences.
- **If yes:** say what happens next.
- **If no:** describe the alternative and its cost.
- **Reversible:** explain whether and how to reverse the decision.

Repeat for each decision. Each question must be answerable in one line, such as “D1: yes”.

## Already decided

- State the decision, its durable owner and a citation to the operator's decision records.

## Proposal

Describe the proposed components, who runs them, and what each component owns. Keep this section to about one page and leave mechanics to How it works.

## How it works

Explain the mechanics needed to assess the proposal using steps, tables, or a diagram, and link to an appendix for detail beyond about two pages.

## Risks and unknowns

| Risk or unknown | Effect if it goes wrong | What handles it | Evidence |
| --- | --- | --- | --- |
| Describe the uncertainty | Describe the effect | Specify the mitigation or first build that tests it | unverified: source needed |

## Plan

| Step | What lands | Done when | Owner |
| --- | --- | --- | --- |
| 1 | First deliverable | A check anyone can run | Durable role |

Exercise unknowns in the first build that depends on them. Remove meetings that only confirm documented behavior.

## Appendices

Create one file per topic and replace these examples with links to real files:

- `A-evidence.md`: evidence, source citations and the proven, existing, new, or unverified labels.
- `B-alternatives.md`: alternatives and reasons for choosing another option.

Remove this section if there are no appendices.

<!-- Copy the skeleton above into README.md. Replace its frontmatter with the
complete example below and remove this comment and the instructions below. -->

## Preparing the files

Copy the skeleton into `README.md` and replace its frontmatter with this complete example:

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

Name each appendix `[A-Z]-<kebab>.md`. Add `type: Design Appendix` and `parent: README.md` frontmatter and a `[Design](README.md)` link back. Link each appendix from the README.

Complete [the writing checklist](WRITING.md) before asking for [review](REVIEW.md).
