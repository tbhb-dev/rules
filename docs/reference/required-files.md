---
description: How the required files check compares a consumer repository with the baseline manifest.
status: stable
tags: [bazel, testing]
title: Required files
type: Reference
generated:
  - role: generated
    harness: claude-code:2.1.322
    model: anthropic:claude-sonnet-5-5
    effort: medium
    surface: cli
    session: sha-256-64:debb814921f029ad
    subagent: sha-256-64:c04c2891d8f854b6
    at: "2026-11-15T09:29:31Z"
---

# The required files

`//repo/tests:check_required_files` checks a consumer root against the baseline `manifest.toml` and `repo.schema.json`. A successful check exits with status 0. Check failures exit with status 1. The checker exits with status 2 if it can't read an input or if the schema fails while it validates the declaration. It doesn't check references in schema parts the declaration doesn't use.

Consumers must declare `kind` and a boolean `private` value in `.tbhb-repo.toml`. The checker combines the selected `[kind.<kind>]` entry with `[visibility.public]` or `[visibility.private]`. Unknown kinds and invalid declarations exit with status 1 only when the manifest and schema are readable.

Manifest tables and their entries must be tables, and each `required` value must be a list of strings. Required paths must be nonempty and relative, with no `..` segment, drive-letter prefix, backslash, newline, or null byte. The checker rejects `.` and `./`. Paths ending in `/` must identify directories. Other paths must identify files. Manifest content problems exit with status 1. Validation stops at the first bad table, entry, or path. Missing paths produce one diagnostic line each.

An `[[exception]]` with `check = "C4"` must specify a path and provide a reason with text. It hides that missing path. Stale exceptions fail the check, with diagnostics in sorted path order.

Unit tests must resolve every declared kind in the real baseline manifest for public and private visibility. Both ordinary test runs and mutation runs must include those baseline files. Fixtures under `repo/tests/testdata/required_files` use a small manifest and run in `//:baseline_tests`. Clean fixtures cover `go` and `docs`. Bad fixtures cover missing files and directories, unknown kinds, bad exceptions and a private repository without its license file. This repository fits no kind and has no `.tbhb-repo.toml`, so the checker doesn't run against its root.

Failure proofs using `expect_failure_test` must set `exit_status` from 0 through 255. A value of 0 accepts any nonzero exit status.
