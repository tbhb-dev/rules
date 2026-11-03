# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`pinned_binary`: a pinned tool file as an executable target."""

def _pinned_binary_impl(ctx):
    # Named after the tool, so a rule that puts the binary's directory on
    # PATH (such as bats_test with git) finds it by its usual name.
    out = ctx.actions.declare_file(ctx.label.name + "/" + ctx.attr.tool)
    ctx.actions.symlink(output = out, target_file = ctx.file.binary, is_executable = True)
    return [DefaultInfo(
        executable = out,
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out, ctx.file.binary]),
    )]

pinned_binary = rule(
    implementation = _pinned_binary_impl,
    doc = "Exposes a downloaded tool file as an executable target named for the tool.",
    executable = True,
    attrs = {
        "binary": attr.label(allow_single_file = True, mandatory = True),
        "tool": attr.string(mandatory = True),
    },
)
