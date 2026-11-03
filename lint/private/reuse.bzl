# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`reuse_test`: the tree complies with the REUSE Specification."""

load("//runtime:defs.bzl", "python_tool")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def reuse_test(name, srcs, **kwargs):
    """Runs `reuse lint` over a copy of `srcs`.

    Every file needs copyright and licensing information, in a header, a
    `.license` file or REUSE.toml, and every license it names must be in
    LICENSES/. The files are exactly `srcs`: the copy has no `.git`, so
    reuse checks the tree, not what git tracks, and `srcs` must leave out
    anything a checkout would ignore. reuse runs on tbhb_rules' own pinned
    Python (@tbhb_rules_python_runtime: reuse with charset-normalizer).

    Args:
        name: Target name.
        srcs: Files to check, usually a `repo_files` target. They must
            include REUSE.toml and LICENSES/.
        **kwargs: Passed to `tree_check_test`.
    """
    python_tool(
        name = name + ".tool",
        tool = "reuse",
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = ["lint"],
        **kwargs
    )
