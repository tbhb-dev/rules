---
description: How the required files check compares a consumer repository with the baseline manifest.
status: stable
tags: [bazel, testing]
title: Required files
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:a380dfec5db32fa9
    at: "2026-11-15T03:02:28Z"
---

# The required files

`//repo/tests:check_required_files` takes the baseline `manifest.toml`, `repo.schema.json` and a consumer's root. It reads `kind` and `private` from the consumer's `.tbhb-repo.toml`, then takes the `required` list of `[kind.<kind>]` plus the one of `[visibility.public]` or `[visibility.private]`. It prints one line for each required path the repository lacks, then fails. A path that ends in `/` must be a directory, and any other path must be a file.

The check also fails for a missing or invalid `.tbhb-repo.toml`, an unknown kind, and a non-boolean `private` value. An `[[exception]]` with `check = "C4"` hides one named path and needs a reason with text. An exception for a path that isn't missing fails. Stale exception diagnostics must appear in path order. A manifest `kind` or `visibility` table, or an entry in one, that isn't a table fails with one line that names it. A required path that is absolute or has a `..` segment fails with one line that names the path.

A successful check must exit with status 0. Check failures must exit with status 1. An unreadable input or an invalid schema must produce a diagnostic and exit with status 2. Each `required` value must be a list of strings.

This repository fits no kind and has no `.tbhb-repo.toml`, so nothing runs the check against it. The fixtures in `repo/tests/testdata/required_files` have a small manifest and run in `//:baseline_tests`. The unit tests must also resolve every kind in the real baseline manifest for public and private visibility. The fixtures hold a clean `go` repository and a clean `docs` repository. The bad repositories show a missing file, a missing directory, an unknown kind, a bad exception, and a private repository without its license file.

Failure proofs using `expect_failure_test` must set `exit_status` from 0 through 255. A value of 0 accepts any nonzero exit status.
