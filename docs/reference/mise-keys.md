---
description: How the mise.toml key check compares this repository with the baseline.
status: stable
tags: [bazel, testing]
title: mise.toml keys
type: Reference
generated:
  - role: generated
    harness: claude-code:2.1.323
    model: anthropic:claude-sonnet-5-5
    effort: medium
    surface: sdk-cli
    session: sha-256-64:327ad4ffb7d7474d
    at: "2026-11-13T16:55:16Z"
---

# The mise.toml keys

`//repo/tests:mise_keys_test` runs in `//:baseline_tests`, which `//:all` includes. It parses `mise.toml` and `repo/baseline/files/mise.toml.baseline` with Python `tomllib` and compares the names of tables and keys. The check ignores values, because tool versions differ. The check prints one line for each name that only one side has, then fails. The `EXCEPTIONS` table in `repo/tests/check_mise_keys.py` gives each current difference a reason, and an entry also covers the tables and keys below it. A planted fixture fails with both line kinds, and a clean fixture passes.
