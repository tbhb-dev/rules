# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A minimal test rule for subjects: runs a script with an environment."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

def _script_test_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = ctx.file.script, is_executable = True)
    executable, runfiles = shell_executable(ctx, out, ctx.runfiles(files = [ctx.file.script]))
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = ctx.attr.env),
    ]

script_test = rule(
    implementation = _script_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "env": attr.string_dict(),
        "script": attr.label(allow_single_file = True, mandatory = True),
    },
)
