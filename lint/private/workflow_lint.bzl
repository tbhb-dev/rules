# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`workflow_lint_test`: pinned actions, fixed runner labels, no public self-hosted runners."""

load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def workflow_lint_test(name, srcs, private = False, paths = [".github"], **kwargs):
    """Checks workflow and action YAML for the rules zizmor does not enforce alone.

    Fails on a `uses:` ref that is not a full commit SHA, on `ubuntu-latest`,
    `macos-latest` and `windows-latest`, and on `self-hosted` unless the
    repository is private. The check does not depend on a zizmor config, so
    loosening that config cannot turn the pin rule off.

    Args:
        name: Target name.
        srcs: Files to check, including `.github/`.
        private: True when the repository is private. Only then may a workflow name `self-hosted`.
        paths: Files or directories to scan, relative to the tree root.
        **kwargs: Passed to tree_check_test.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = Label(":workflow_lint.sh"),
        tool_args = (["--private"] if private else []) + paths,
        output_guard = "workflow_lint: scanned [1-9]",
        **kwargs
    )
