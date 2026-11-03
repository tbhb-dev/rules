# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `format` target with a workspace that is not a git checkout."""

def _outside_git_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = """#!/usr/bin/env bash
set -euo pipefail
workspace="$TEST_TMPDIR/workspace"
mkdir -p "$workspace"
echo 'a=1' >"$workspace/bad.toml"
BUILD_WORKSPACE_DIRECTORY="$workspace" GIT_CEILING_DIRECTORIES="$TEST_TMPDIR" "$PWD/{}"
""".format(ctx.executable.subject.short_path),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject]).merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = driver, runfiles = runfiles)]

outside_git_test = rule(
    implementation = _outside_git_test_impl,
    test = True,
    attrs = {"subject": attr.label(mandatory = True, executable = True, cfg = "target")},
)
