# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runnable review control detector for the caller's checkout."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

visibility("//lint/...")

_RUNNER = """#!/usr/bin/env bash
set -euo pipefail
runfiles=$PWD
cd "${{BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}}"
"$runfiles/{python}" "$runfiles/{main}" --git "$runfiles/{git}" "$@"
"""

def _controls_changed_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = _RUNNER.format(
            python = ctx.executable._python.short_path,
            main = ctx.file._main.short_path,
            git = ctx.executable._git.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.file._main, ctx.file._categories, ctx.executable._python, ctx.executable._git])
    for tool in [ctx.attr._python, ctx.attr._git]:
        runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

controls_changed = rule(
    implementation = _controls_changed_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = "Reports review control paths in BASE..HEAD; findings exit zero.",
    attrs = SHELL_ATTRS | {
        "_categories": attr.label(default = ":controls_changed/categories.json", allow_single_file = True),
        "_git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "_main": attr.label(default = ":controls_changed/check_controls.py", allow_single_file = True),
        "_python": attr.label(default = ":controls_changed_python", executable = True, cfg = "target"),
    },
)
