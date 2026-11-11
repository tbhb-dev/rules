---
type: Reference
title: Design writing checklist
description: Checks a writer completes before asking for a design review.
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

# Design writing checklist

Start with [the template](TEMPLATE.md). Complete these checks across the README and all appendices before asking for [review](REVIEW.md).

- [ ] Fill in the required frontmatter, status table, and open decision count. Run `design_test` with the repository's forbidden terms and resolve every finding.
- [ ] Put Summary and Decisions for tbhb first. Keep the Summary within 150 words and three paragraphs. State the problem, proposal, recommendation, and effect on tbhb.
- [ ] Keep only tbhb's irreversible choices, credentials or grants, trust boundary changes, and standing rules as D items. Give each item Recommendation, Why, If yes, If no and Reversible bullets and a question answerable in one line.
- [ ] Search the operator's decision records before asking a question. Move answered questions and reversible choices to Already decided, with citations to records that exist and support the text.
- [ ] Run available read-only checks and record their results before asking for a decision. Keep questions for tbhb out of all other sections and appendices.
- [ ] Keep README.md to about 250 lines. Move evidence, alternatives, history and long mechanics into topic appendices with the required names, frontmatter, and links in both directions.
- [ ] Label factual claims proven, existing, new or unverified, and cite primary sources in appendix A. Use brief evidence citations in the main text and reconcile contradictions with records, merged code, and current designs.
- [ ] Specify durable roles and components, what runs them, and where they store their state. Don't use a long-running coordinating session as a component or depend on today's arrangement of sessions.
- [ ] Give every risk a mitigation or a first build that tests it. Give every plan step an owner and a Done when check anyone can run. Remove meetings that only confirm documented behavior.
- [ ] Check the operator's standing rules and preserve credential, spending, authority, stop, and review controls. Explicitly identify decisions that would change a rule.
- [ ] Remove private host names, paths, repository names, network details, and other private information from public designs. Paraphrase tbhb instead of quoting verbatim.
- [ ] Use paragraphs of at most three sentences, bullets for lists of three or more items, plain words, and paths in backticks. Define each term at first use and use its name consistently.
- [ ] Ask an independent reviewer to read every file and check primary sources at the current commit. Resolve blocking findings before presenting the design to tbhb.
