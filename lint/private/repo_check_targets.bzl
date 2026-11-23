# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Package target inventory for the repo checks drift test."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")

visibility(["//", "//lint"])

def repo_check_targets(repo):
    """Records the targets already declared in this package.

    Args:
        repo: The repository prefix used in the workflow.
    """
    prefix = "{}//{}:".format(repo, native.package_name())
    write_file(
        name = "repo_check_targets",
        out = "repo_check_targets.txt",
        content = [prefix + name for name in sorted(native.existing_rules())],
        visibility = ["//lint/tests/repo_checks:__pkg__"],
    )
