---
description: Export, lint, and refresh committed Structurizr workspace diagrams.
status: stable
tags: [architecture, bazel]
title: Structurizr tooling
type: Readme
generated:
  - role: generated
    harness: claude-code:2.1.322
    model: anthropic:claude-sonnet-5-5
    effort: medium
    surface: cli
    session: sha-256-64:debb814921f029ad
    subagent: sha-256-64:a5922f2e895088d6
    at: "2026-11-15T06:42:51Z"
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

The pinned tools render with a headless Java runtime and Smetana, using Liberation Sans 2.1.5 (`SIL OFL 1.1`) from the `tbhb_rules_liberation_fonts` hub. Fontconfig lists only the pinned font directory and a scratch cache. Rendering also checks that the Java virtual machine opens each pinned TrueType font and that each SVG specifies Liberation Sans. No test covers those failures yet. Linux needs host `libfontconfig` and `libfreetype`.

JSON and SVG comparisons use bytes on every supported platform (Linux and macOS on x64 and arm64). Linux x86_64 CI proved SVG and JSON byte-identical to the committed files generated on macOS arm64. The Java virtual machine uses Coordinated Universal Time (UTC) and the en_US.UTF-8 locale. PNG byte comparisons run only on macOS arm64. PNG measurements use Structurizr 2025.11.09, Temurin 21.0.13+9, PlantUML 1.2026.10, and Liberation Sans 2.1.5. Missing and orphan images fail on every supported platform.

The CI plan selects Linux x86_64, Linux arm64 and macOS arm64 for Structurizr and excludes Windows because the Java runtime pins cover Linux and macOS only. The only CI run read so far ran Structurizr on Linux x86_64, before the plan added Linux arm64 and macOS arm64. No Linux arm64 or macOS CI result is recorded here, and Windows is unsupported.

Treat workspace sources as trusted input. Java HTTP(S) requests use an unreachable proxy and PlantUML uses its sandbox profile, but `!script`, `!plugin`, and absolute `!include` directives can access the host. The pinned command-line tool doesn't expose a restricted mode for validation, inspection, or export. Use only trusted workspace sources and imports. Name the source `workspace.dsl`.

Frontmatter `at` timestamps use Coordinated Universal Time (UTC).

The macro reference at `docs/reference/structurizr.md` documents inspection severities, imported inputs, tool pins, and overrides.
