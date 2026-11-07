# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Shell script checks that find the scripts themselves.

Both macros run their tool over every shell script in `srcs`: files named
`*.sh`, `*.bash` or `*.bats`, and files whose first line is a sh, bash,
dash, ksh or bats shebang. A tree with no scripts fails unless
`allow_empty` is set.
"""

load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

_SELECT = Label(":shell_select.sh")

def _selector_args(allow_empty, exclude, tool_name, tool_args):
    args = ["--allow-empty"] if allow_empty else []
    for pattern in exclude:
        args += ["--exclude", pattern]
    return args + ["--", tool_name] + tool_args

def shellcheck_test(
        name,
        srcs,
        args = ["-o", "check-extra-masked-returns"],
        allow_empty = False,
        exclude = [],
        tool = Label("@tbhb_rules_shellcheck//:shellcheck"),
        **kwargs):
    """Lints every shell script in `srcs` with shellcheck.

    shellcheck reads `.shellcheckrc` files among `srcs` as usual.

    Args:
        name: Target name.
        srcs: Files to search for scripts, usually a `repo_files` target.
        args: shellcheck options, before the scripts.
        allow_empty: Pass when `srcs` holds no shell scripts, instead of
            failing. It lets a repository with no scripts keep the check,
            so a script added later is checked.
        exclude: bash `[[ == ]]` patterns of tree-relative paths to skip,
            such as fixtures that are broken on purpose.
        tool: The shellcheck binary. Its basename must be `shellcheck`.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = _SELECT,
        tool_args = _selector_args(allow_empty, exclude, "shellcheck", args),
        path_tools = [tool],
        **kwargs
    )

def shfmt_test(
        name,
        srcs,
        allow_empty = False,
        exclude = [],
        tool = Label("@tbhb_rules_shfmt//:shfmt"),
        **kwargs):
    """Fails when `shfmt -d` would reformat any shell script in `srcs`.

    shfmt takes its style from the `.editorconfig` files among `srcs`.

    Args:
        name: Target name.
        srcs: Files to search for scripts, usually a `repo_files` target.
        allow_empty: Pass when `srcs` holds no shell scripts, instead of
            failing. It lets a repository with no scripts keep the check,
            so a script added later is checked.
        exclude: bash `[[ == ]]` patterns of tree-relative paths to skip.
        tool: The shfmt binary. Its basename must be `shfmt`.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = _SELECT,
        tool_args = _selector_args(allow_empty, exclude, "shfmt", ["-d"]),
        path_tools = [tool],
        **kwargs
    )
