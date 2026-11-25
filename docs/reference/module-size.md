---
description: Source and test file size limits and how to adopt them in a repository.
status: stable
tags: [bazel, testing]
title: Module size
type: Reference
generated:
  - role: generated
    harness: codex:0.171.0
    model: openai:gpt-6.2-sol
    effort: high
    surface: exec
    session: sha-256-64:1ae74bfaf6a7e800
    at: "2026-11-25T14:49:52Z"
---

# Module size

The module size check counts physical lines in Git-tracked files in the calling worktree, including nested workspaces. Blank lines and a final line without a line ending count. LF and CRLF each end one line, and an empty file has zero lines. Each source file has a 500-line limit. Each test file has a 1,000-line limit because tests often include setup, fixtures, and several cases.

The shared repository checks run `module_size` in CI. To run it from a consuming repository that depends on `tbhb_rules`:

```sh
bazelisk run @tbhb_rules//lint:module_size
```

The check reads `.github/module-size.toml` if present. Pass `-- --config path/to/module-size.toml` to use another file for a call. Set the top-level integers `source_limit` and `test_limit` to change the limits independently.

Configure file selection with the arrays `source_globs`, `test_globs`, and `ignore_globs`. An array replaces its default. Patterns match complete repository-relative paths with forward slashes. Use `**/` for any directory depth, including the root. The check selects source matches, drops ignore matches, and applies the test limit to the remaining test matches.

- Source defaults match files ending in `.py`, `.go`, `.ts`, `.tsx`, `.js`, `.rs`, `.swift`, `.kt`, `.java`, `.c`, `.h`, `.cc`, `.cpp`, or `.sh`.
- Test defaults are `**/test_*.py`, `**/*_test.py`, `**/*_test.go`, `**/*.test.ts`, `**/*.test.tsx`, `**/*.spec.ts`, `**/*Tests.swift`, `**/*Test.swift`, `**/tests/**`, and `**/__tests__/**`.
- Ignore defaults are `**/node_modules/**`, `**/vendor/**`, `**/.bazel*/**`, `**/*.pb.go`, `**/*_pb2.py`, and `**/generated/**`.

## Baseline

The baseline uses TOML, like the repository check registry. To adopt the check in a repository with oversized files, run the separate helper and copy its `[baseline]` table into `.github/module-size.toml`. Use the same config for both commands. The helper prints a snapshot to standard output and runs only when called.

```sh
bazelisk run @tbhb_rules//lint:module_size_baseline
```

Each baseline key is a quoted repository-relative path and each value is its current line count. A listed file that remains over the limit must match its recorded count. If the file grows, shorten or split it. If it shrinks but remains over the limit, lower its entry to the new count. Remove entries for files that meet the limit, disappear, or fall outside the configured globs. New oversized files fail the check.
