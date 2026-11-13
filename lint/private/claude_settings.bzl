# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`claude_settings_test`: repository permissions and MCP server consistency."""

load("//runtime:defs.bzl", "python_tool")
load(":tree_check.bzl", "tree_check_test")

visibility("//lint/...")

def claude_settings_test(name, srcs, settings = ".claude/settings.json", mcp = ".mcp.json", **kwargs):
    """Checks required PR denials and MCP permissions using only JSON.

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        settings: Settings path relative to the copied tree root.
        mcp: MCP configuration path relative to the copied tree root.
        **kwargs: Passed to `tree_check_test`.
    """
    python_tool(
        name = name + ".tool",
        main = Label("//lint/private/claude_settings:check_claude_settings.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = [settings, mcp],
        **kwargs
    )
