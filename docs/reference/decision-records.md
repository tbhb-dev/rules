---
description: Where decision records live, how to name them, and what their bodies contain.
status: draft
tags: [decisions, docs]
title: Decision records
type: Reference
---

# Decision records

Decision records describe a choice and its consequences in the repository's OKF docs bundle.

## Location and naming

Store records at `docs/decisions/NNNN-<slug>.md`. Use four digits for the number, including `0000`. A slug uses lowercase letters and digits, with single hyphens between words. Filenames match `^\d{4}-[a-z0-9]+(-[a-z0-9]+)*\.md$`.

Keep each merged file's name. If main contains a duplicate number, renumber the later record in a new commit. Only this fix-forward renumber changes a merged filename.

Append each record's index entry at the end of `docs/decisions/index.md`. This makes two pull requests that add a record conflict on the index. Before merging, the later pull request renumbers its record.

## Body

The title states the decision. Use these sections in order:

- `Context`: describe the problem and the constraints on the choice.
- `Decision`: state the choice in the present tense. Name nobody and quote nobody.
- `Options considered` (optional): describe the alternatives and why they don't fit.
- `Consequences`: describe the effects and tradeoffs of the choice.

<!-- vale ai-tells.ExplainerHeadings = NO -->
## What the check enforces
<!-- vale ai-tells.ExplainerHeadings = YES -->

`decision_records_test` checks the filename pattern and unique numbers. It scans only the directory's immediate children and rejects subdirectories and non-Markdown files. It exempts `index.md`, `AGENTS.md`, and `CLAUDE.md` from the filename and number rules. A missing directory passes.

Run `bazelisk test //:decision_records_test` to check the repository's record names. The check never reads file contents.

## Frontmatter

A later change defines the frontmatter fields.
