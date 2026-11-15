---
description: Rules for writing and updating a Structurizr workspace.
status: stable
tags: [architecture, docs]
title: Structurizr workspace writing
type: Writing Checklist
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:fcedc7c9c8a10316
    at: "2026-11-15T02:47:26Z"
---

# Structurizr workspace writing

- Start with the [workspace template](structurizr-workspace-template.md).
- Give each element a description and each container a technology.
- Give relationships a description and protocol where applicable.
- Use stable view keys and explicit view scope.
- Keep imported documentation and decisions local. Declare them in `data`.
- Use the [macro update target](../reference/structurizr.md) after changing the workspace source.
- Commit JSON, SVG and PNG exports together with the workspace source.
- Require both validation and inspection to pass with no errors or warnings.
