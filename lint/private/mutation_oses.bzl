# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`mutation_oses_test`: source-derived mutation platform requirements."""

load("//runtime:defs.bzl", "python_tool")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def mutation_oses_test(name, srcs, **kwargs):
    """Checks explicit mutation_oses restrictions against Go and Python sources.

    Unset and None preserve all current OSes and pass. A restricted list must
    contain every OS implied by platform-specific code. See the mutation OS
    reference for source scope, signals, and literal attribute requirements.

    Args:
        name: Target name.
        srcs: BUILD files and sources, usually a repo_files target.
        **kwargs: Passed to tree_check_test.
    """
    python_tool(
        name = name + ".tool",
        main = Label(":mutation_oses/check_mutation_oses.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        **kwargs
    )
