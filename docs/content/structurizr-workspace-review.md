---
description: Rules for reviewing a Structurizr workspace and its exports.
status: stable
tags: [architecture, docs]
title: Structurizr workspace REVIEW
type: Review Checklist
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:fcedc7c9c8a10316
    at: "2026-11-15T02:44:22Z"
---

# Structurizr workspace REVIEW

- Check the [writing rules](structurizr-workspace-writing.md).
- Verify model boundaries, responsibilities and relationships against implementation evidence.
- Check view keys for unintended renames.
- Review exported JSON and every diagram alongside the DSL change.
- Require passing validation, inspection and freshness tests.
- Require one main diagram and one legend in each image format per view.
- Reject missing diagrams and diagrams with no workspace view.
- Apply the measured PNG platform rule in the [macro reference](../reference/structurizr.md).
