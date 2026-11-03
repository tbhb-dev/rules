# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The launcher that runs the tools of the locked Python environment."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load(":env_info.bzl", "PyEnvInfo")

# Internal: load //runtime:defs.bzl.
visibility("//runtime/...")

def _python_tool_impl(ctx):
    env = ctx.attr.python_env[PyEnvInfo]
    options = []
    if ctx.attr.select:
        options.append("--select")
    if ctx.attr.allow_empty:
        options.append("--allow-empty")
    for pattern in ctx.attr.exclude:
        options += ["--exclude", pattern]
    if ctx.attr.chdir:
        options += ["--chdir", ctx.attr.chdir]

    source_roots = list(env.source_roots)
    if ctx.attr.source_roots_from:
        source_roots.extend(ctx.attr.source_roots_from[PyEnvInfo].source_roots)
    source_roots.extend(ctx.attr.extra_source_roots)

    script = ctx.actions.declare_file(ctx.label.name)
    boot = ctx.file._sitecustomize.short_path.rpartition("/")[0]
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        substitutions = {
            "@@BIN@@": env.bin_dir,
            "@@BOOT@@": boot,
            "@@INTERPRETER@@": env.interpreter.short_path,
            "@@LAUNCH@@": ctx.file._launch.short_path,
            "@@OPTIONS@@": " ".join([shell.quote(o) for o in options]),
            "@@SELF@@": shell.quote(script.short_path),
            "@@SITE_PACKAGES@@": env.site_packages,
            "@@SOURCE_ROOTS@@": " ".join([shell.quote(r) for r in source_roots]),
            "@@TOOL@@": (
                'python "$base"/' + shell.quote(ctx.file.main.short_path) if ctx.file.main else shell.quote(ctx.attr.tool)
            ),
            "@@UV@@": env.uv.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = [ctx.file._launch, ctx.file._sitecustomize] + ([ctx.file.main] if ctx.file.main else []),
        transitive_files = env.files,
    )
    return [DefaultInfo(executable = script, runfiles = runfiles)]

python_tool = rule(
    implementation = _python_tool_impl,
    executable = True,
    doc = """An executable that runs one tool of the locked Python environment.

`tool` is `python`, `uv`, a console script of an installed package, or an
executable in the environment's bin directory. It runs from the current
directory with the environment's site-packages and the workspace members'
source roots (relative to the current directory) importable.""",
    attrs = {
        "allow_empty": attr.bool(doc = "With `select`, finding no Python file is not an error."),
        "chdir": attr.string(doc = "Directory, relative to the current one, to run the tool from."),
        "exclude": attr.string_list(doc = "fnmatch patterns of relative paths `select` skips."),
        "extra_source_roots": attr.string_list(doc = "More directories, relative to the current one, to put on the path."),
        "main": attr.label(allow_single_file = [".py"], doc = "A Python file to run with the interpreter instead of `tool`."),
        "python_env": attr.label(
            mandatory = True,
            providers = [PyEnvInfo],
            doc = "The environment whose interpreter and packages run the tool.",
        ),
        "select": attr.bool(doc = "Append the Python files (by suffix or shebang) under the run directory to the arguments."),
        "source_roots_from": attr.label(
            providers = [PyEnvInfo],
            doc = "Another environment whose workspace members' source roots go on the path too, for a tool of one environment that analyses another's sources.",
        ),
        "tool": attr.string(default = "python", doc = "The tool to run."),
        "_launch": attr.label(default = Label(":launch.py"), allow_single_file = True),
        "_sitecustomize": attr.label(default = Label("//runtime/private/boot:sitecustomize.py"), allow_single_file = True),
        "_template": attr.label(default = Label(":launch.sh.tpl"), allow_single_file = True),
    },
)
