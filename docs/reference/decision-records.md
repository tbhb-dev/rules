---
description: Where decision records live, their names and frontmatter, and what the check enforces.
status: stable
tags: [decisions, docs]
title: Decision records
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:dad369cdbe656815
    at: "2026-11-10T03:34:40Z"
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

## Checks

`decision_records_test` checks the filename pattern, unique numbers, and replacement references. It scans only the directory's immediate children and rejects subdirectories and non-Markdown files. It exempts `index.md`, `AGENTS.md`, and `CLAUDE.md` from the record checks. A missing directory passes.

For each file with a valid record name, `superseded_by`, when present, references an existing record number in the same directory. The check compares the integer to the four-digit filename number as an integer. A record can't name itself. These failures read `<path>: superseded_by <N> names no record` and `<path>: superseded_by names itself`.

The check skips frontmatter it can't read. `okf_docs_test` validates frontmatter against the schema, including field types. The schema allows `superseded_by` only on deprecated records.

Run `bazelisk test //:decision_records_test //:okf_docs_test` to check records and frontmatter.

## Frontmatter

Use the [document fields](frontmatter.md) with `type: Decision Record`. The required `decided` field is the decision date in `YYYY-MM-DD` form. Quote it. Only Decision Records accept `decided` and `superseded_by`.

```yaml
---
type: Decision Record
title: Use numbered decision records
description: Record repository decisions in the docs bundle.
tags: [decisions, docs]
status: stable
decided: "2026-11-09"
# superseded_by: 2  # Optional; allowed only with status: deprecated.
generated:
  - role: generated
    harness: codex
    model: openai:gpt-6.1-sol
    at: "2026-11-10T03:30:00Z"
---
```

Set each `generated` entry from its contributor's identity and the time of the latest change.

| Record | `status` | `superseded_by` |
| --- | --- | --- |
| In force | `stable` | Absent. |
| Superseded or withdrawn | `deprecated` | Superseded: the integer number of the replacement record. Withdrawn: absent. |

A repository without a docs bundle creates it (index and schemas) with its first record and copies the [frontmatter schema](../schemas/frontmatter.schema.json) then.
