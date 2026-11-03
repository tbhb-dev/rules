# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`pinned_binary`: a pinned tool file as an executable target."""

load("//shell:defs.bzl", "SHELL_ATTRS", "ToolDirInfo", "is_windows")

def _rlocation(ctx, file):
    """The file's path under the runfiles root."""
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    return ctx.workspace_name + "/" + file.short_path

def _pinned_binary_impl(ctx):
    # Named after the tool, so a rule that puts the binary's directory on
    # PATH (such as bats_test with git) finds it by its usual name.
    out = ctx.actions.declare_file(ctx.label.name + "/" + ctx.attr.tool)
    runfiles = ctx.runfiles(files = [out, ctx.file.binary] + ctx.files.data)
    path = out
    if is_windows(ctx):
        path = ctx.file.binary

        # A symlink to a Windows binary would leave it unable to find the
        # files beside it (Git for Windows' own tree), and every caller is a
        # Bash script, so a Bash shim runs the binary where it lies in the
        # runfiles tree.
        up = "/".join([".."] * _rlocation(ctx, out).count("/"))
        ctx.actions.write(
            output = out,
            content = '#!/usr/bin/env bash\nexec "$(dirname "${{BASH_SOURCE[0]}}")/{}/{}" "$@"\n'.format(
                up,
                _rlocation(ctx, ctx.file.binary),
            ),
            is_executable = True,
        )
    else:
        ctx.actions.symlink(output = out, target_file = ctx.file.binary, is_executable = True)
    return [
        DefaultInfo(executable = out, files = depset([out]), runfiles = runfiles),
        ToolDirInfo(dir = path.short_path.rpartition("/")[0]),
    ]

pinned_binary = rule(
    implementation = _pinned_binary_impl,
    doc = "Exposes a downloaded tool file as an executable target named for the tool.",
    executable = True,
    attrs = SHELL_ATTRS | {
        "binary": attr.label(allow_single_file = True, mandatory = True),
        "data": attr.label_list(allow_files = True, doc = "Files the binary needs beside it."),
        "tool": attr.string(mandatory = True),
    },
)
