# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`tree_check`: a test that runs one tool over a real copy of a file tree."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _tree_path(file, strip_prefix):
    # A file from another repository would land at `../repo/...` in the copy,
    # outside the tree, so only main-repository files are accepted.
    if file.owner.repo_name != "":
        fail("{} is from repository @{}; only files of the main repository can be checked".format(
            file.short_path,
            file.owner.repo_name,
        ))
    if not strip_prefix:
        return file.short_path
    if not file.short_path.startswith(strip_prefix + "/"):
        fail("{} is not under strip_prefix {}".format(file.short_path, strip_prefix))
    return file.short_path[len(strip_prefix) + 1:]

def _tree_check_impl(ctx):
    config = ctx.file.config
    strip_prefix = ctx.attr.strip_prefix.strip("/")
    files = depset(
        direct = [config] if config else [],
        transitive = [depset(ctx.files.srcs), depset(ctx.files.data)],
    )

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join([_tree_path(f, strip_prefix) + "\n" for f in files.to_list()]),
    )

    # Files a tool reads from its cache instead of the network, such as
    # pinned copies of the JSON Schemas a config refers to.
    cache_files = []
    cache_lines = []
    for target, dest in ctx.attr.cache_files.items():
        if dest.startswith("/") or ".." in dest.split("/"):
            fail("cache_files: {} is not a relative path inside the cache".format(dest))
        for f in target.files.to_list():
            cache_files.append(f)
            cache_lines.append("{}\t{}\n".format(f.short_path, dest))
    cache_manifest = ctx.actions.declare_file(ctx.label.name + ".cache_manifest")
    ctx.actions.write(output = cache_manifest, content = "".join(cache_lines))

    tool_args = [
        arg.replace("{config}", _tree_path(config, strip_prefix)) if config else arg
        for arg in ctx.attr.tool_args
    ]
    for arg in tool_args:
        if "{config}" in arg:
            fail("tool_args uses {config}, but no config is set")

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@CACHE_MANIFEST@@": cache_manifest.short_path,
            "@@GIT_ROOT@@": "1" if ctx.attr.git_root else "",
            "@@MANIFEST@@": manifest.short_path,
            "@@MIN_FILES@@": str(ctx.attr.min_files),
            "@@OUTPUT_GUARD@@": shell.quote(ctx.attr.output_guard),
            "@@PATH_TOOLS@@": " ".join([shell.quote(path_dir(t)) for t in ctx.attr.path_tools]) or "",
            "@@STRIP_PREFIX@@": shell.quote(strip_prefix),
            "@@TOOL@@": ctx.executable.tool.short_path,
            "@@TOOL_ARGS@@": " ".join([shell.quote(a) for a in tool_args]),
        },
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [manifest, cache_manifest] + cache_files, transitive_files = files)
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    for path_tool in ctx.attr.path_tools:
        runfiles = runfiles.merge(path_tool[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.runfiles(files = [ctx.executable.tool] + ctx.files.path_tools))
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = ctx.attr.env,
            inherited_environment = ctx.attr.env_inherit,
        ),
        testing.ExecutionInfo(ctx.attr.execution_requirements),
    ]

tree_check_test = rule(
    implementation = _tree_check_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Runs `tool` with `tool_args` at the root of a dereferenced copy of
`srcs`, `data` and `config`, laid out at their repository-relative paths
(relative to `strip_prefix` when set).

Fails when the copy holds fewer than `min_files` files or zero bytes, and,
if `output_guard` is set, when the tool exits 0 and its combined output
does not match it; a tool that fails has reported its own failure.
Both failures say what was scanned, so a check that silently stopped seeing
its inputs is diagnosable.""",
    attrs = SHELL_ATTRS | {
        "cache_files": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Files to place under a private `XDG_CACHE_HOME`, keyed to their path inside it.",
        ),
        "config": attr.label(
            allow_single_file = True,
            doc = "The tool's config file. `{config}` in `tool_args` expands to its repository-relative path.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Other files the tool or its config reads (ignore lists, dictionaries, styles).",
        ),
        "env": attr.string_dict(
            doc = "Environment variables for the tool.",
        ),
        "env_inherit": attr.string_list(
            doc = "Environment variables the tool takes from the environment Bazel runs in. Their values join the test's action key.",
        ),
        "execution_requirements": attr.string_dict(
            doc = "Execution requirements for the test action, such as `no-remote-cache`, which tags can't set through a `select`.",
        ),
        "git_root": attr.bool(
            doc = "Create an empty `.git` directory at the tree root, for tools that find the project by it. It holds no Git metadata.",
        ),
        "min_files": attr.int(
            default = 1,
            doc = "Fail when the copy holds fewer files than this.",
        ),
        "output_guard": attr.string(
            doc = "Extended regular expression the tool's output must match, such as a 'scanned N bytes' line.",
        ),
        "path_tools": attr.label_list(
            allow_files = True,
            cfg = "target",
            doc = "Executables put on PATH for the tool, by basename.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Files to check, usually a `repo_files` target.",
        ),
        "strip_prefix": attr.string(
            doc = "Repository-relative directory to use as the root of the copy, to check a subtree (a nested project, a fixture) as if it were the repository. Every file must be under it.",
        ),
        "tool": attr.label(
            mandatory = True,
            executable = True,
            allow_files = True,
            cfg = "target",
            doc = "The tool to run: an executable target or a checked-in script.",
        ),
        "tool_args": attr.string_list(
            doc = "Arguments passed to the tool before any test `args`.",
        ),
        "_runner": attr.label(
            default = ":tree_check.sh.tpl",
            allow_single_file = True,
        ),
    },
)
