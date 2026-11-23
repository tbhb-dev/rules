# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""List the Bazel rules in a package for the repo-checks drift test."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")

def repo_check_targets(visibility = None):
    """Write a list of labels. Call this after declaring the package's rules.

    Args:
        visibility: Visibility of the list target.
    """
    prefix = "//{}:".format(native.package_name())
    write_file(
        name = "repo_check_targets",
        out = "repo_check_targets.txt",
        content = [prefix + name for name in sorted(native.existing_rules())],
        visibility = visibility,
    )
