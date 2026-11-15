---
description: How the required files check compares a consumer repository with the baseline manifest.
status: stable
tags: [bazel, testing]
title: Required files
type: Reference
generated:
  - role: generated
    harness: codex:0.166.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:5d5dba04b8b34f60
    at: "2026-11-15T19:37:20Z"
---

# The required files

`//repo/tests:check_required_files` checks a consumer root against the baseline `manifest.toml` and `repo.schema.json`. Exit status must be 0 for success, 1 for check failures, or 2 for an unreadable input or a schema that fails validation.

Consumers must declare `kind` and a boolean `private` value in `.tbhb-repo.toml`. The checker combines the selected `[kind.<kind>]` entry with `[visibility.public]` or `[visibility.private]`. Unknown kinds and invalid declarations fail the check.

Manifest tables and their entries must be tables, and each `required` value must be a list of strings. Required paths must be relative and contain no `..` segment. Paths ending in `/` must identify directories. Other paths must identify files. Table errors, invalid paths and missing paths produce one diagnostic line per failure.

An `[[exception]]` with `check = "C4"` must name a path and provide a reason with text. It hides that missing path. Stale exceptions fail the check, with diagnostics in sorted path order.

Unit tests must resolve every declared kind in the real baseline manifest for public and private visibility. Both ordinary test runs and mutation runs must include those baseline files. Fixtures under `repo/tests/testdata/required_files` use a small manifest and run in `//:baseline_tests`. Clean fixtures cover `go` and `docs`. Bad fixtures cover missing files and directories, unknown kinds, bad exceptions and a private repository without its license file. This repository fits no kind and has no `.tbhb-repo.toml`, so the checker doesn't run against its root.

Failure proofs using `expect_failure_test` must set `exit_status` from 0 through 255. A value of 0 accepts any nonzero exit status.
