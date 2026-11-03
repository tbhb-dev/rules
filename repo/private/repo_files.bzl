# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Implementation of `repo_files`."""

# Internal: consumers load //repo:defs.bzl.
visibility("//repo/...")

def repo_files(name = "repo_files", exclude = [], exclude_subpackages = [], visibility = None, **kwargs):
    """Every file in this package and, recursively, in its subpackages.

    `glob()` stops at package boundaries, so a whole-tree check that globs
    from the root never sees a file that lives in a subpackage. This macro
    collects the package's own files plus the same-named target of each
    direct subpackage, so calling it in every BUILD file chains the whole
    tree together. The chain fails closed: a subpackage that does not call
    the macro has no such target, and analysis of the parent fails.

    Directories that hold no source (VCS metadata, virtualenvs, caches) are
    best kept out of every package with `ignore_directories` in REPO.bazel;
    `exclude` takes the remaining per-package file patterns.

    Args:
        name: Target name. Every package in the chain must use the same one.
        exclude: Glob patterns to leave out of this package's files.
        exclude_subpackages: Patterns of subpackages to leave out of the
            chain. Needed for directories in `.bazelignore` that hold BUILD
            files, such as nested modules: `subpackages()` lists them
            anyway, and loading one fails as a deleted package.
        visibility: Defaults to public, so a parent package can depend on it.
        **kwargs: Passed to the underlying `filegroup`.
    """
    package = native.package_name()

    # Bazel's convenience symlinks (bazel-bin, bazel-<repo>, ...) sit at the
    # root. Unless REPO.bazel ignores them, glob() follows them into the
    # output tree, and `subpackages()` lists them even when it does; loading
    # one fails as a deleted package.
    skip = (["bazel-*"] if not package else []) + exclude_subpackages
    exclude = exclude + ["bazel-*/**"] if not package else exclude
    subpackages = [
        "//{}:{}".format(package + "/" + sub if package else sub, name)
        for sub in native.subpackages(include = ["**"], exclude = skip, allow_empty = True)
    ]
    native.filegroup(
        name = name,
        srcs = native.glob(["**"], exclude = exclude, allow_empty = True) + subpackages,
        visibility = visibility or ["//visibility:public"],
        **kwargs
    )
