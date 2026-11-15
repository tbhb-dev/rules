---
description: Required structure for a Structurizr workspace source.
status: stable
tags: [architecture, docs]
title: Structurizr workspace template
type: Content Template
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:fcedc7c9c8a10316
    at: "2026-11-15T02:47:26Z"
---

# Structurizr workspace template

Keep the workspace source at `docs/architecture/workspace.dsl`. Commit `workspace.json` beside it and SVG and PNG files under `docs/architecture/diagrams/`.

```text
workspace "System" "Purpose of the system." {
    model {
        user = person "User" "Uses the system."
        system = softwareSystem "System" "Provides a service."
        user -> system "Uses" "HTTPS"
    }
    views {
        systemContext system "context" "System context." {
            include *
            autoLayout lr
        }
    }
    configuration {
        scope softwaresystem
    }
}
```

Replace names and descriptions with current responsibilities. Add containers, technologies, and views that explain the system. Follow the [writing rules](structurizr-workspace-writing.md).
