# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`codeowners_test`: every CODEOWNERS pattern still matches a file."""

load(":checks.bzl", "GIT_TEST_ENV")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def codeowners_test(
        name,
        srcs,
        codeowners = ".github/CODEOWNERS",
        tool = Label(":codeowners.sh"),
        git = Label("@tbhb_rules_git//:git"),
        **kwargs):
    """Fails when a CODEOWNERS pattern matches no file in `srcs`.

    A rule whose pattern matches nothing is usually left over from a rename,
    and GitHub reports no error for it. CODEOWNERS patterns follow the
    .gitignore rules, so Git's own matching decides (`git ls-files --others
    --ignored --exclude-from`), using the pinned git, never the host's.
    GitHub's owner and syntax validation needs the API and stays outside the
    test graph.

    The pinned git is the `bin/git` of dugite-native, run through a wrapper
    that points it at its own files: on Linux it needs glibc 2.34 or newer.

    Args:
        name: Target name.
        srcs: Files the patterns are matched against, usually a `repo_files`
            target. It must include the CODEOWNERS file.
        codeowners: Repository-relative path of the CODEOWNERS file.
        tool: The checker script.
        git: The git binary put on PATH. Its basename must be `git`.
        **kwargs: Passed to `tree_check_test`.
    """
    env = dict(GIT_TEST_ENV)
    env.update(kwargs.pop("env", {}))
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = tool,
        tool_args = [codeowners],
        path_tools = [git],
        env = env,
        **kwargs
    )
