# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a generated Bash script as a rule's executable, on Windows too."""

_SH_TOOLCHAIN = "@rules_shell//shell:toolchain_type"

SHELL_TOOLCHAINS = [config_common.toolchain_type(_SH_TOOLCHAIN, mandatory = False)]

ToolDirInfo = provider(
    doc = """Where a tool lives for PATH lookups by its usual name.

A Bash shim (the pinned tools on Windows) runs only under Bash; a native
program that runs the tool by name (gitleaks running git) needs the real
binary's directory on PATH.""",
    fields = {"dir": "The directory's short path."},
)

def path_dir(target):
    """The short path of the directory to put on PATH for an executable target."""
    if ToolDirInfo in target:
        return target[ToolDirInfo].dir
    return target[DefaultInfo].files_to_run.executable.short_path.rpartition("/")[0]

SHELL_ATTRS = {
    "_windows": attr.label(default = "@platforms//os:windows"),
}

def is_windows(ctx):
    """Whether the rule builds for Windows. The rule needs SHELL_ATTRS."""
    return ctx.target_platform_has_constraint(ctx.attr._windows[platform_common.ConstraintValueInfo])

def shell_executable(ctx, script, runfiles):
    """The executable and runfiles that run `script`.

    Elsewhere the script is the executable. Windows runs only .exe, .bat and
    .cmd files, so there a .bat beside the script runs it with the shell
    toolchain's Bash. The rule needs SHELL_ATTRS and SHELL_TOOLCHAINS, and
    `script` must sit in the package directory.

    Args:
        ctx: The rule context.
        script: The generated Bash script.
        runfiles: The executable's runfiles, without the script.

    Returns:
        A tuple of the executable File and the runfiles to return with it.
    """
    runfiles = runfiles.merge(ctx.runfiles(files = [script]))
    if not is_windows(ctx):
        return script, runfiles
    sh = ctx.toolchains[_SH_TOOLCHAIN]
    if not sh or not sh.path:
        fail("{}: Windows needs a shell toolchain; set BAZEL_SH to bash.exe".format(ctx.label))
    bash = sh.path.replace("/", "\\")
    launcher = ctx.actions.declare_file(ctx.label.name + ".bat")
    ctx.actions.write(
        output = launcher,
        content = "\r\n".join([
            "@echo off",
            # Bash started from cmd would otherwise find Windows' find and
            # sort ahead of its own.
            'set "PATH={};%PATH%"'.format(bash.rpartition("\\")[0]),
            # Bazel's test runner exports PWD in Windows form (C:\...), and
            # MSYS2's Bash keeps it, so "$PWD/..." on a colon-separated PATH
            # splits at the drive. Unset, Bash takes the POSIX form.
            'set "PWD="',
            '"{}" "%~dp0{}" %*'.format(bash, script.basename),
            "exit /b %ERRORLEVEL%",
            "",
        ]),
        is_executable = True,
    )
    return launcher, runfiles
