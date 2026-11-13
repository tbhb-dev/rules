---
description: Temporary file paths and the shell source check.
status: stable
tags: [bazel, testing]
title: Temporary files
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:f094385401c69cac
    at: "2026-11-13T12:33:33Z"
---

# Temporary files

Pass a template to `mktemp`. Shell scripts and templates use `mktemp "${TMPDIR:-/tmp}/<name>.XXXXXX"` for files and add `-d` for directories, while GitHub workflows and their fetch script use `${RUNNER_TEMP:-${TMPDIR:-/tmp}}` as the directory. Bazel tests can use `${TEST_TMPDIR:-${TMPDIR:-/tmp}}`. The template keeps macOS temporary files inside the chosen directory. Run `bazelisk test //:mktemp_tests` to scan tracked `*.sh`, `*.sh.tpl`, and `*.yml` files across nested modules and check clean and failing fixtures. The check reports the file, line, and fix.
