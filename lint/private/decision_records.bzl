# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`decision_records_test`: decision record filenames and unique numbers."""

load("//runtime:defs.bzl", "python_tool")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def decision_records_test(name, srcs, directory = "docs/decisions", **kwargs):
    """Checks decision record filenames and unique four-digit numbers.

    Checks the immediate children of `directory`, when present. Every child
    must be a Markdown file. Apart from index.md, AGENTS.md and CLAUDE.md,
    filenames must be NNNN-<slug>.md with a lowercase kebab-case slug and a
    unique number. File contents are never read.

    The files are exactly `srcs`, copied, never `git ls-files`. The checker
    runs on tbhb_rules' own pinned Python.

    Args:
        name: Target name.
        srcs: Files to check, usually a `repo_files` target.
        directory: Decision records directory, relative to the root.
        **kwargs: Passed to `tree_check_test`.
    """
    python_tool(
        name = name + ".tool",
        main = Label(":decision_records/check_decisions.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = ["--directory", directory],
        **kwargs
    )
