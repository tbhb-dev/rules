# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A minimal test rule for subjects: runs a script with an environment."""

def _script_test_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = ctx.file.script, is_executable = True)
    return [
        DefaultInfo(executable = out, runfiles = ctx.runfiles(files = [ctx.file.script])),
        RunEnvironmentInfo(environment = ctx.attr.env),
    ]

script_test = rule(
    implementation = _script_test_impl,
    test = True,
    attrs = {
        "env": attr.string_dict(),
        "script": attr.label(allow_single_file = True, mandatory = True),
    },
)
