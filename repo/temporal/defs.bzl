# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run a command against an isolated Temporal development server."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//runtime:defs.bzl", "PyEnvInfo")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "ToolDirInfo", "is_windows", "shell_executable")

def _runfile_arg(ctx, path):
    rlocation = path[3:] if path.startswith("../") else ctx.workspace_name + "/" + path
    return '"$root"/' + shell.quote(rlocation)

def _dev_server_impl(ctx):
    cli = ctx.attr._cli
    cli_path = cli[DefaultInfo].files_to_run.executable.short_path
    if is_windows(ctx) and ToolDirInfo in cli:
        # Python needs the native executable behind the pin hub's Bash shim.
        cli_path = cli[ToolDirInfo].dir + "/temporal.exe"

    python = ctx.attr._python[PyEnvInfo]
    runfiles = ctx.runfiles(
        files = [ctx.file._main] + ctx.files.data,
        transitive_files = python.files,
    ).merge(cli[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge_all([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    command = ""
    if ctx.executable.command:
        command = _runfile_arg(ctx, ctx.executable.command.short_path) + " "
        runfiles = runfiles.merge(ctx.runfiles(files = [ctx.executable.command]))
        runfiles = runfiles.merge(ctx.attr.command[DefaultInfo].default_runfiles)

    script = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = script,
        content = "\n".join([
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            'root="${RUNFILES_DIR:-${TEST_SRCDIR:-$0.runfiles}}"',
            'root="$(cd "$root" && pwd)"',
            'exec {} -I {} {} {}"$@"'.format(
                _runfile_arg(ctx, python.interpreter.short_path),
                _runfile_arg(ctx, ctx.file._main.short_path),
                _runfile_arg(ctx, cli_path),
                command,
            ),
            "",
        ]),
        is_executable = True,
    )
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_ATTRS = SHELL_ATTRS | {
    "command": attr.label(executable = True, cfg = "target", doc = "Executable to run with TEMPORAL_ADDRESS set."),
    "data": attr.label_list(allow_files = True, doc = "Additional command runfiles."),
    "_cli": attr.label(default = "@tbhb_rules_temporal//:temporal"),
    "_main": attr.label(allow_single_file = True, default = Label(":dev_server.py")),
    "_python": attr.label(default = "@tbhb_rules_python_runtime//:env", providers = [PyEnvInfo]),
}

temporal_dev_server = rule(
    implementation = _dev_server_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = _ATTRS,
    doc = "Starts a Temporal dev server. Pass a command after `--` or leave it running in the foreground.",
)

temporal_dev_server_test = rule(
    implementation = _dev_server_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = _ATTRS | {
        "command": attr.label(executable = True, cfg = "target", mandatory = True, doc = "Test executable to run with TEMPORAL_ADDRESS set."),
    },
    doc = "Runs a test executable against an isolated Temporal dev server.",
)
