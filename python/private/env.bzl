# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The locked Python environment and the launcher that runs its tools."""

load("@bazel_skylib//lib:shell.bzl", "shell")

# Internal: consumers load //:defs.bzl.
visibility("//...")

PyEnvInfo = provider(
    doc = "A locked Python environment built by the `python` module extension.",
    fields = {
        "bin_dir": "short_path of the environment's bin directory (native tools such as ruff).",
        "files": "depset of every file of the interpreter and the environment.",
        "interpreter": "The interpreter File.",
        "site_packages": "short_path of the site-packages directory.",
        "source_roots": "Source roots of the editable workspace members, relative to the workspace root.",
        "uv": "The uv File.",
    },
)

def _dir_of(files, directory):
    # A path inside the repository becomes a short_path, which is how
    # runfiles name it.
    if not files:
        fail("the environment has no files under {}".format(directory))
    sample = files[0].short_path
    marker = "/" + directory + "/"
    index = sample.find(marker)
    if index < 0:
        fail("{} is not under {}".format(sample, directory))
    return sample[:index + len(marker) - 1]

def _python_env_impl(ctx):
    return [
        PyEnvInfo(
            bin_dir = _dir_of(ctx.files.bin, ctx.attr.bin_dir),
            files = depset(
                [ctx.file.interpreter, ctx.file.uv],
                transitive = [depset(ctx.files.python), depset(ctx.files.site_packages), depset(ctx.files.bin)],
            ),
            interpreter = ctx.file.interpreter,
            site_packages = _dir_of(ctx.files.site_packages, ctx.attr.site_packages_dir),
            source_roots = ctx.attr.source_roots,
            uv = ctx.file.uv,
        ),
    ]

python_env = rule(
    implementation = _python_env_impl,
    doc = "Wraps the files of the `tbhb_python` repository in a PyEnvInfo.",
    attrs = {
        "bin": attr.label_list(allow_files = True),
        "bin_dir": attr.string(mandatory = True),
        "interpreter": attr.label(allow_single_file = True, mandatory = True),
        "python": attr.label_list(allow_files = True),
        "site_packages": attr.label_list(allow_files = True),
        "site_packages_dir": attr.string(mandatory = True),
        "source_roots": attr.string_list(),
        "uv": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _python_env_unconfigured_impl(ctx):
    fail(("{}: no Python project is declared. Add to the root MODULE.bazel:\n" +
          "  python = use_extension(\"@tbhb_rules_python//:extensions.bzl\", \"python\")\n" +
          "  python.project()").format(ctx.label))

python_env_unconfigured = rule(
    implementation = _python_env_unconfigured_impl,
    doc = "Stands in for the environment when the root module declares no project.",
)

def _python_tool_impl(ctx):
    env = ctx.attr.env[PyEnvInfo]
    options = []
    if ctx.attr.select:
        options.append("--select")
    if ctx.attr.allow_empty:
        options.append("--allow-empty")
    for pattern in ctx.attr.exclude:
        options += ["--exclude", pattern]
    if ctx.attr.chdir:
        options += ["--chdir", ctx.attr.chdir]

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
            "@@SOURCE_ROOTS@@": " ".join([shell.quote(r) for r in env.source_roots]),
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
        "env": attr.label(
            default = Label("@tbhb_python//:env"),
            providers = [PyEnvInfo],
            doc = "The environment.",
        ),
        "exclude": attr.string_list(doc = "fnmatch patterns of relative paths `select` skips."),
        "main": attr.label(allow_single_file = [".py"], doc = "A Python file to run with the interpreter instead of `tool`."),
        "select": attr.bool(doc = "Append the Python files (by suffix or shebang) under the run directory to the arguments."),
        "tool": attr.string(default = "python", doc = "The tool to run."),
        "_launch": attr.label(default = ":launch.py", allow_single_file = True),
        "_sitecustomize": attr.label(default = "//private/boot:sitecustomize.py", allow_single_file = True),
        "_template": attr.label(default = ":launch.sh.tpl", allow_single_file = True),
    },
)
