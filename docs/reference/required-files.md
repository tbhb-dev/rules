---
description: How the required files check compares a consumer repository with the baseline manifest.
status: stable
tags: [bazel, testing]
title: Required files
type: Reference
generated:
  - role: generated
    harness: codex:0.167.2
    model: openai:gpt-6.1-sol
    effort: medium
    surface: exec
    session: sha-256-64:c4b2c8ec9c83fe74
    at: "2026-11-14T23:28:07Z"
---

# The required files

`//repo/tests:check_required_files` takes the baseline `manifest.toml`, `repo.schema.json` and a consumer's root. It reads `kind` and `private` from the consumer's `.tbhb-repo.toml`, then takes the `required` list of `[kind.<kind>]` plus the one of `[visibility.public]` or `[visibility.private]`. It prints one line for each required path the repository lacks, then fails. A path that ends in `/` must be a directory, and any other path must be a file.

The check also fails for a missing or invalid `.tbhb-repo.toml`, an unknown kind, and a non-boolean `private` value. An `[[exception]]` with `check = "C4"` hides one named path and needs a reason with text. An exception for a path that isn't missing fails.

This repository fits no kind and has no `.tbhb-repo.toml`, so nothing runs the check against it. The fixtures in `repo/tests/testdata/required_files` have a small manifest and run in `//:baseline_tests`. They hold a clean `go` repository and a clean `docs` repository. The bad repositories show a missing file, a missing directory, an unknown kind, a bad exception, and a private repository without its license file.
