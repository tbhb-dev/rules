# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Check that required statuses and CI conclusion dependencies agree."""

load("//runtime:defs.bzl", "python_tool")
load(":tree_check.bzl", "tree_check_test")

visibility("//lint/...")

def required_status_checks_test(name, srcs, ruleset = ".github/rulesets/main.json", workflow = ".github/workflows/ci.yml", **kwargs):
    """Checks required contexts and conclusion's complete, nonexempt needs list.

    Contexts match job display names, falling back to job ids. Every context
    must identify conclusion. Its needs list uses job ids and must contain
    every other job except the documented exemptions in the checker.
    Runs on tbhb_rules' pinned Python and PyYAML, over copies of `srcs`.

    Args:
        name: Target name.
        srcs: Files to check, usually a `repo_files` target.
        ruleset: Ruleset JSON path relative to the copied tree root.
        workflow: CI workflow YAML path relative to the copied tree root.
        **kwargs: Passed to `tree_check_test`.
    """
    python_tool(
        name = name + ".tool",
        main = Label("//lint/private/required_status_checks:check_status_checks.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = [ruleset, workflow],
        **kwargs
    )
