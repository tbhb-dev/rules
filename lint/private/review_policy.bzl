# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`review_policy_test`: a tree's review policy files meet the org floor."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//runtime:defs.bzl", "python_tool")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

_SCRIPT = """#!/usr/bin/env bash
set -euo pipefail
# The runfiles root, as python_tool finds it: the tests that run this tool
# set one of these.
if [[ -n ${{RUNFILES_DIR:-}} ]]; then
  base=$RUNFILES_DIR/_main
elif [[ -n ${{TEST_SRCDIR:-}} ]]; then
  base=$TEST_SRCDIR/_main
else
  echo "review_policy: run it from a test" >&2
  exit 1
fi
exec "$base"/{checker} "$base"/{source} "$@"
"""

def _review_policy_tool_impl(ctx):
    # The marker is tbhbdev's package __init__, so its directory's parent is
    # the source root that makes `tbhbdev` importable.
    source = ctx.file.source_marker.short_path.removesuffix("/tbhbdev/__init__.py")
    script = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = script,
        content = _SCRIPT.format(
            checker = shell.quote(ctx.executable.checker.short_path),
            source = shell.quote(source),
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.checker], transitive_files = depset(ctx.files.source))
    runfiles = runfiles.merge(ctx.attr.checker[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_review_policy_tool = rule(
    implementation = _review_policy_tool_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Runs `checker` with the path of tbhbdev's source root as its first argument.

The source tree is runfiles of this tool, so a test that runs it from a
scratch directory still finds it.""",
    attrs = SHELL_ATTRS | {
        "checker": attr.label(mandatory = True, executable = True, cfg = "target"),
        "source": attr.label(mandatory = True, allow_files = True),
        "source_marker": attr.label(mandatory = True, allow_single_file = True),
    },
)

def review_policy_test(name, srcs, path = ".", **kwargs):
    """Runs tbhbdev's `alpha review policy check` over a copy of `srcs`.

    The check reads the review files a repository has under `.github`
    (pull_request_review.toml, PULL_REQUEST_REVIEW_TEMPLATE.md,
    PULL_REQUEST_REVIEW_CHECKLIST.md and schemas/pull-request-review-draft.schema.json)
    and a missing file passes. tbhbdev is the source archive pinned in
    MODULE.bazel, run on the Python of @tbhb_rules_review_policy_runtime.

    Args:
        name: Target name.
        srcs: The files to check, laid out at their repository-relative paths.
        path: The path to check, relative to the copy. A file there makes the
            check fail to load, which a proof test uses.
        **kwargs: Passed to `tree_check_test`.
    """
    python_tool(
        name = name + ".checker",
        main = Label("//lint/private/review_policy:check_review_policy.py"),
        python_env = Label("@tbhb_rules_review_policy_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    _review_policy_tool(
        name = name + ".tool",
        checker = ":{}.checker".format(name),
        source = Label("@tbhb_rules_tbhbdev_src//:src"),
        source_marker = Label("@tbhb_rules_tbhbdev_src//:src/tbhbdev/__init__.py"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = [path],
        **kwargs
    )
