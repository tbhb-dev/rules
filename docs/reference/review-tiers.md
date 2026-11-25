---
description: Path declarations and review requirements for changes to this repository.
status: stable
tags: [review, docs]
title: Review tiers
type: Reference
generated:
  - role: generated
    harness: codex:0.171.0
    model: openai:gpt-6.2-sol
    effort: medium
    surface: exec
    session: sha-256-64:ad9a931d9518fef4
    at: "2026-11-25T03:15:43Z"
---

# Review tiers

This file declares tier 2 paths for `tbhb_rules` under the 2026-11-24 review-tier ruling.

Determine the tier from the paths a diff touches before review. A reviewer may raise the tier. Nothing lowers it.

Tier 2 requires two fresh review runs. Each run uses a provider other than the builder's and a different `--variant`. Any session may launch them.

Tier 1 requires one review run from a provider other than the builder's. Tier 0 is prose only and follows the existing prose rules.

A diff that touches any path listed below requires tier 2. The match is by file because a path cannot name a section of a file. The tier requirements in [AGENTS.md](../../AGENTS.md) also apply.

## Class 2 — crossing the agent account boundary

The class 2 paths in [AGENTS.md](../../AGENTS.md) cover the repository's agent settings and deny rules. This declaration adds no class 2 paths. A diff that changes approval or merge rights, or the means to stop agents, requires tier 2 whatever the path.

## Class 3 — merge-gate enforcement

- `.github/rulesets/*` and `.github/workflows/ci.yml` set the branch rules and required CI checks.
- `.github/workflows/tier0-approval.yml` and `repo/private/tier0_approval/**` govern automatic approval of tier 0 changes.
- `.github/actions/ci-conclusion/**` and `lint/private/required_status_checks/**` enforce and check the required CI conclusion.
- `.github/CODEOWNERS` sets who owns paths for review and approval.
- `.github/PULL_REQUEST_TEMPLATE.md` and `.github/pull-request-sections.toml` define what a pull request must include.
- `docs/reference/review-severity.md` and `docs/content/*-review.md` define what a review asks for.
- `docs/reference/review-tiers.md` declares the review tiers.

## Class 1 — deleting durable data

This repository has no code that deletes durable data.

## Tier 1

All other code or configuration changes, including changes to workflows outside the tier 2 paths and changes to tests, require tier 1. Prose-only changes under `docs/` outside the tier 2 paths are tier 0.
