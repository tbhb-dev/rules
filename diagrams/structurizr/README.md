---
description: Export, lint, and refresh committed Structurizr workspace diagrams.
status: stable
tags: [architecture, bazel]
title: Structurizr tooling
type: Readme
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:fcedc7c9c8a10316
    at: "2026-11-15T02:47:26Z"
---

# Structurizr tooling

Load `structurizr_workspace` from `@tbhb_rules_structurizr//:defs.bzl`.

```starlark
structurizr_workspace(
    name = "architecture",
    dsl = "docs/architecture/workspace.dsl",
    workspace_json = "docs/architecture/workspace.json",
    diagrams_dir = "docs/architecture/diagrams",
)
```

Run `bazel run :architecture` to update committed exports and `bazel test :architecture_test` to check validation, inspection, and freshness. `:architecture.renders` contains JSON, PlantUML text, SVG and PNG exports.

The pinned tools render offline with a headless JRE and Smetana. JSON and SVG comparisons use bytes on every supported platform. PNG comparisons run only on macOS arm64, where repeated JVM runs produced identical bytes. Missing and orphan images fail on all supported platforms. Windows is unsupported.

The macro reference at `docs/reference/structurizr.md` documents inspection severities, imported inputs, tool pins, and overrides.
