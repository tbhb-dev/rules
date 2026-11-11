---
description: Repository layout attributes, required files, and failure diagnostics.
status: stable
tags: [repo, testing]
title: Repository layout
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:1a3b568a9619d1df
    at: "2026-11-11T18:35:30Z"
---

# Repository layout

Load `repo_layout_test` from `@tbhb_rules//repo:defs.bzl`. The test checks files in `srcs` against directory and script rules. It reports each problem as `path: problem` and fails if it finds any problems or has no files to check.

## Attributes

| Attribute | Value |
| --- | --- |
| `srcs` | Input files, often a `repo_files` target. Required. |
| `strip_prefix` | Repository-relative directory to treat as the root. Defaults to the repository root. |
| `top_level_dirs` | Allowed top-level directory names. Must contain at least one name. The test skips top-level files. |
| `scripts` | Top-level directory to script kind. Defaults to `{}`. The supported kind is `pep723`. |
| `allowed_subdirs` | Script directory to allowed immediate subdirectory names. Defaults to `{}`. Files beneath these subdirectories are exempt from script checks. |
| `required_files` | Directory path to filenames required directly in each immediate subdirectory. Defaults to `{}`. The check permits extra files. |

## Required files

```starlark
repo_layout_test(
    name = "layout_test",
    srcs = [":repo_files"],
    required_files = {"templates": ["TEMPLATE.md", "WRITING.md", "REVIEW.md"]},
    top_level_dirs = ["templates"],
)
```

With this layout, `templates/alpha/` must contain `TEMPLATE.md`, `WRITING.md` and `REVIEW.md` once any descendant file appears in `srcs`. Other immediate subdirectories of `templates/` have the same requirements. The test permits extra files alongside `TEMPLATE.md`, `WRITING.md` and `REVIEW.md`. Nested directories, such as `templates/alpha/notes/`, don't inherit the list. A file at `templates/alpha/notes/REVIEW.md` doesn't count as `templates/alpha/REVIEW.md`.

Directory keys use paths relative to `strip_prefix` and support nested directories, such as `docs/templates`. They must not be absolute or contain empty, `.` or `..` components. Each listed filename must contain exactly one component. The checker rejects tabs and newlines in keys and names.

The checker derives directories from file paths in `srcs`. A directory becomes visible when `srcs` names a file beneath it, including deeper descendants. Empty directories and directories outside `srcs` remain invisible. A missing directory key fails even with an empty list. Existing keys with no immediate subdirectories pass. Leaving the dictionary empty preserves the existing layout checks.

Missing files produce separate diagnostics, including two failures for the same subdirectory:

```text
templates/alpha/: missing required file WRITING.md
templates/alpha/: missing required file REVIEW.md
```

A missing directory key reports `templates/: required_files directory does not exist in srcs`.

## Script directories

`scripts` keys must appear in `top_level_dirs`. A `pep723` file directly in a script directory has no extension. Its first line must equal `#!/usr/bin/env -S uv run --script`. A later line must equal `# /// script`. The directory can contain only subdirectories from `allowed_subdirs`.

## Inputs and checks

`repo_files` collects the files Bazel sees, including files across package boundaries. Ignores in `REPO.bazel` apply. `.gitignore` doesn't filter the input. With `strip_prefix`, every input file must be beneath that prefix. The checker rejects files from external repositories.

Run `bazelisk test //repo/...` for analysis tests, passing fixtures, and failure proofs. The failure proofs use `expect_failure_test` to require the expected rejection. Separate proofs check both diagnostics when one subdirectory lacks two required files.
