# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Formatters: `formatter`, the `format` runners and `format_test`."""

load("@bazel_skylib//lib:shell.bzl", "shell")

# Internal: consumers load //format:defs.bzl.
visibility("//format/...")

FormatterInfo = provider(
    doc = "One formatter: a tool, the files it takes, and how to fix and check them.",
    fields = {
        "check_args": "Arguments that check without writing and exit non-zero on unformatted input.",
        "fix_args": "Arguments that rewrite files in place.",
        "include": "Bash glob patterns, matched against each repository-relative path and its basename.",
        "tool": "The executable File.",
        "tool_runfiles": "The tool's runfiles.",
    },
)

def _formatter_impl(ctx):
    if not ctx.attr.include:
        fail("include must name at least one pattern")
    if not ctx.attr.check_args:
        fail("check_args must not be empty: a check must not write")
    return [FormatterInfo(
        check_args = ctx.attr.check_args,
        fix_args = ctx.attr.fix_args,
        include = ctx.attr.include,
        tool = ctx.executable.tool,
        tool_runfiles = ctx.attr.tool[DefaultInfo].default_runfiles,
    )]

formatter = rule(
    implementation = _formatter_impl,
    doc = """Declares a formatter for `format` and `format_test`.

The selected files are appended to `fix_args` or `check_args`, and the tool
runs at the root of the workspace (or of the test's copy).""",
    attrs = {
        "check_args": attr.string_list(doc = "Arguments that check without writing and exit non-zero on unformatted input."),
        "fix_args": attr.string_list(doc = "Arguments that rewrite files in place."),
        "include": attr.string_list(doc = "Bash glob patterns, matched against each repository-relative path and its basename; `*` also matches `/`."),
        "tool": attr.label(
            mandatory = True,
            executable = True,
            allow_files = True,
            cfg = "target",
            doc = "The formatter executable.",
        ),
    },
)

def _display(label):
    prefix = "@{}".format(label.repo_name) if label.repo_name else ""
    return "{}//{}:{}".format(prefix, label.package, label.name)

def _calls(formatters, mode):
    lines = []
    for target in formatters:
        info = target[FormatterInfo]
        args = info.check_args if mode == "check" else info.fix_args
        words = [_display(target.label), info.tool.short_path, str(len(info.include))] + info.include + [str(len(args))] + args
        lines.append("run_formatter " + " ".join([shell.quote(w) for w in words]))
    return "\n".join(lines)

def _runfiles(ctx, formatters, extra = []):
    runfiles = ctx.runfiles(files = extra + [t[FormatterInfo].tool for t in formatters])
    for target in formatters:
        runfiles = runfiles.merge(target[FormatterInfo].tool_runfiles)
    return runfiles

def _script(ctx, mode, source, manifest = None, strip_prefix = ""):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@CALLS@@": _calls(ctx.attr.formatters, mode),
            "@@EXCLUDES@@": " ".join([shell.quote(p) for p in ctx.attr.exclude]),
            "@@MANIFEST@@": manifest.short_path if manifest else "",
            "@@MODE@@": mode,
            "@@SOURCE@@": source,
            "@@STRIP_PREFIX@@": shell.quote(strip_prefix),
        },
        is_executable = True,
    )
    return script

_COMMON_ATTRS = {
    "exclude": attr.string_list(
        doc = "Bash glob patterns for files no formatter may touch, such as deliberately malformed test fixtures; matched like `include`.",
    ),
    "formatters": attr.label_list(
        mandatory = True,
        providers = [FormatterInfo],
        doc = "`formatter` targets.",
    ),
    "_runner": attr.label(
        default = ":format.sh.tpl",
        allow_single_file = True,
    ),
}

def _format_run_impl(ctx):
    script = _script(ctx, ctx.attr.mode, "workspace")
    return [DefaultInfo(executable = script, runfiles = _runfiles(ctx, ctx.attr.formatters))]

format_run = rule(
    implementation = _format_run_impl,
    executable = True,
    attrs = dict(_COMMON_ATTRS, mode = attr.string(mandatory = True, values = ["check", "fix"])),
)

def _tree_path(file, strip_prefix):
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

def _format_test_impl(ctx):
    strip_prefix = ctx.attr.strip_prefix.strip("/")
    files = depset(ctx.files.srcs)
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join([_tree_path(f, strip_prefix) + "\n" for f in files.to_list()]),
    )
    script = _script(ctx, "check", "copy", manifest, strip_prefix)
    runfiles = _runfiles(ctx, ctx.attr.formatters, [manifest]).merge(ctx.runfiles(transitive_files = files))
    return [DefaultInfo(executable = script, runfiles = runfiles)]

format_test = rule(
    implementation = _format_test_impl,
    test = True,
    doc = """Fails when any file in `srcs` is not formatted according to `formatters`.

Runs each formatter's `check_args` over a dereferenced copy of `srcs`, laid
out at their repository-relative paths (relative to `strip_prefix` when
set), so formatters that read config files from the tree find them.""",
    attrs = dict(
        _COMMON_ATTRS,
        srcs = attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Files to check, usually a `repo_files` target.",
        ),
        strip_prefix = attr.string(doc = "Repository-relative directory to use as the root of the copy."),
    ),
)

def format(name, formatters, **kwargs):
    """Creates `<name>` and `<name>.check`, both for `bazel run`.

    `bazel run //:<name>` rewrites the workspace's tracked and untracked,
    unignored files in place; `bazel run //:<name>.check` only checks them
    and fails on any unformatted file. For a cached check in `bazel test`,
    use `format_test` with the same formatters.

    Args:
        name: Name of the fixing target; the checker is `<name>.check`.
        formatters: `formatter` targets.
        **kwargs: Passed to both targets.
    """
    format_run(name = name, formatters = formatters, mode = "fix", **kwargs)
    format_run(name = name + ".check", formatters = formatters, mode = "check", **kwargs)
