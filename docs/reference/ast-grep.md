---
description: How to run ast-grep over declared Bazel sources.
status: stable
tags: [bazel, lint]
title: ast-grep lint
type: Reference
generated:
  - role: generated
    harness: codex:0.171.0
    model: openai:gpt-6.2-sol
    effort: high
    surface: exec
    session: sha-256-64:0cfbdf41150e3aef
    at: "2026-11-25T14:46:03Z"
---

# ast-grep lint

Load `ast_grep_lint` from `@tbhb_rules//lint:defs.bzl`. Pass a `filegroup` for each rule directory. Each `filegroup` includes one `sgconfig.yml` and all rules and utilities it references within that directory. `srcs` contains source files from the consuming repository. The target uses the pinned ast-grep binary, preserves repository-relative source paths, and fails on matches from enabled rules at any severity.

```starlark
load("@tbhb_rules//lint:defs.bzl", "ast_grep_lint")

ast_grep_lint(
    name = "ast_lint",
    rule_dirs = ["//quality:ast_grep_rules"],
    srcs = glob(["tests/**/*.py"]),
)
```

`bazel run //:ast_lint` scans all declared sources. `bazel run //:ast_lint -- --changed origin/main` scans declared sources whose tracked paths differ from the merge base of `origin/main` and `HEAD`. The base ref must exist locally. The scan reads the current checkout, including staged and unstaged changes to tracked files. A changed scan with no selected sources passes.
