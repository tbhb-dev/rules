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
    at: "2026-11-15T15:10:03Z"
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

The pinned tools render with a headless Java runtime and Smetana, using Liberation Sans 2.1.5 (`SIL OFL 1.1`) from the `tbhb_rules_liberation_fonts` hub. On Linux, a generated font configuration lists only the pinned font directory and a scratch cache, and Linux needs host `libfontconfig` and `libfreetype`. On macOS, nothing restricts host fonts. The renderer checks each pinned TrueType font through the JVM's fontconfig mappings or registration on Linux, and through registration on macOS. Each SVG must specify Liberation Sans. A manual run on macOS arm64 showed the font log lists the pinned fonts with the pinned directory and lists none without it. A stubbed JVM test rejects system font paths, missing faces, wrong families, and filename suffixes on both paths; it also rejects fontconfig mappings alone on macOS.

JSON and SVG comparisons use bytes. Linux x86_64 and macOS arm64 produce byte-identical JSON and SVG output, checked against the committed files. Linux arm64 is in the CI plan but has no recorded measurement, and macOS x86_64 has no CI leg. The Java virtual machine uses Coordinated Universal Time (UTC) and the en_US.UTF-8 locale. The freshness test reports that committed JSON and SVG exports are current and that it didn't compare PNG bytes. The PNG test compares bytes and reports that committed PNG exports are current only on macOS arm64; stale PNGs fail only there. The update target writes PNGs only there. PNG measurements use Structurizr 2025.11.09, Temurin 21.0.13+9, PlantUML 1.2026.10, and Liberation Sans 2.1.5. Missing and orphan SVGs and PNGs fail on every platform.

The CI plan selects Linux x86_64, Linux arm64 and macOS arm64 for Structurizr and excludes Windows because the Java runtime pins cover Linux and macOS only.

Treat workspace sources as trusted input. Java HTTP(S) requests use an unreachable proxy and PlantUML uses its sandbox profile, but `!script`, `!plugin`, and absolute `!include` directives can access the host. The pinned command-line tool doesn't expose a restricted mode for validation, inspection, or export. Use only trusted workspace sources and imports. Name the source `workspace.dsl`.

The macro reference at `docs/reference/structurizr.md` documents inspection severities, imported inputs, tool pins, and overrides.
