---
description: What the workflow lint check rejects in workflow and action YAML, and what it skips.
status: stable
tags: [bazel, github-actions]
title: Workflow lint
type: Reference
generated:
  - role: generated
    harness: claude-code:2.1.323
    model: anthropic:claude-sonnet-5-5
    effort: medium
    surface: sdk-cli
    session: sha-256-64:29c2dad05f87d8c9
    at: "2026-11-13T16:47:44Z"
---

# Workflow lint

Load `workflow_lint_test` from `@tbhb_rules//lint:defs.bzl` and give `srcs` a `repo_files` target. A run reads every `.yml` and `.yaml` file under `.github`. A `uses:` ref other than a full 40-character commit hash fails the run, and so does a `ubuntu-latest`, `macos-latest` or `windows-latest` runner label. A `self-hosted` label fails it too, unless the target sets `private = True` for a private repository. Each message gives the file, the line, and the fix. Local `./` actions and `docker://` references are exempt, because a local action shares the caller's commit and a Docker image pins a digest. Comments never count. The zizmor `unpinned-uses` audit also checks pins, but it follows the zizmor config, while this test keeps the rule when that config changes.
