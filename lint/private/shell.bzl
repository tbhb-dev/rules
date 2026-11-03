# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Shell script checks that find the scripts themselves.

Both macros run their tool over every shell script in `srcs`: files named
`*.sh`, `*.bash` or `*.bats`, and files whose first line is a sh, bash,
dash, ksh or bats shebang. A tree with no scripts fails.
"""

load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

_SELECT = Label(":shell_select.sh")

def _selector_args(exclude, tool_name, tool_args):
    args = []
    for pattern in exclude:
        args += ["--exclude", pattern]
    return args + ["--", tool_name] + tool_args

def shellcheck_test(
        name,
        srcs,
        args = ["-o", "check-extra-masked-returns"],
        exclude = [],
        tool = Label("@multitool//tools/shellcheck"),
        **kwargs):
    """Lints every shell script in `srcs` with shellcheck.

    shellcheck reads `.shellcheckrc` files among `srcs` as usual.

    Args:
        name: Target name.
        srcs: Files to search for scripts, usually a `repo_files` target.
        args: shellcheck options, before the scripts.
        exclude: bash `[[ == ]]` patterns of tree-relative paths to skip,
            such as fixtures that are broken on purpose.
        tool: The shellcheck binary. Its basename must be `shellcheck`.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = _SELECT,
        tool_args = _selector_args(exclude, "shellcheck", args),
        path_tools = [tool],
        **kwargs
    )

def shfmt_test(name, srcs, exclude = [], tool = Label("@multitool//tools/shfmt"), **kwargs):
    """Fails when `shfmt -d` would reformat any shell script in `srcs`.

    shfmt takes its style from the `.editorconfig` files among `srcs`.

    Args:
        name: Target name.
        srcs: Files to search for scripts, usually a `repo_files` target.
        exclude: bash `[[ == ]]` patterns of tree-relative paths to skip.
        tool: The shfmt binary. Its basename must be `shfmt`.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = _SELECT,
        tool_args = _selector_args(exclude, "shfmt", ["-d"]),
        path_tools = [tool],
        **kwargs
    )
