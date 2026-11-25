# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Scan declared source files with one or more ast-grep projects."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

visibility("//lint/...")

def _ast_grep_impl(ctx):
    configs = []
    for target in ctx.attr.rule_dirs:
        files = target.files.to_list()
        found = [f for f in files if f.basename == "sgconfig.yml"]
        if len(found) != 1:
            fail("{} must contain exactly one sgconfig.yml".format(target.label))
        config = found[0]
        prefix = config.short_path[:-len(config.basename)]
        if any([not f.short_path.startswith(prefix) for f in files]):
            fail("{} must contain files under the directory of its sgconfig.yml".format(target.label))
        configs.append(config.short_path)

    # A separate runfiles tree lets the runner intersect Git paths with srcs.
    source_dir = ctx.label.name + ".srcs"
    if ctx.label.package:
        source_dir = ctx.label.package + "/" + source_dir
    sources = {}
    paths = []
    for f in ctx.files.srcs:
        if not f.is_source or f.short_path.startswith("../"):
            fail("srcs must be source files in the main repository: {}".format(f.short_path))
        sources[source_dir + "/" + f.short_path] = f
        paths.append(f.short_path + "\000")
    manifest = ctx.actions.declare_file(ctx.label.name + ".sources")
    ctx.actions.write(output = manifest, content = "".join(paths))

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@CONFIGS@@": " ".join([shell.quote(path) for path in configs]),
            "@@GIT_DIR@@": shell.quote(path_dir(ctx.attr._git)),
            "@@MANIFEST@@": shell.quote(manifest.short_path),
            "@@MERGE_BASE@@": shell.quote(ctx.executable._merge_base.short_path),
            "@@SOURCES@@": shell.quote(source_dir),
            "@@TOOL@@": shell.quote(ctx.executable.tool.short_path),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = [manifest, ctx.executable.tool, ctx.executable._merge_base] + ctx.files.rule_dirs,
        symlinks = sources,
    )
    for target in [ctx.attr.tool, ctx.attr._git, ctx.attr._merge_base]:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

ast_grep_lint = rule(
    implementation = _ast_grep_impl,
    doc = "Runs ast-grep over all declared sources, or with `--changed BASE` over changed tracked sources.",
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "rule_dirs": attr.label_list(allow_empty = False, mandatory = True, doc = "One filegroup per directory, containing sgconfig.yml and its rules."),
        "srcs": attr.label_list(allow_files = True, doc = "Source files in the main repository."),
        "tool": attr.label(default = "@tbhb_rules_ast_grep//:ast-grep", executable = True, cfg = "target"),
        "_git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target"),
        "_merge_base": attr.label(default = "//lint:pr_merge_base", executable = True, cfg = "target"),
        "_runner": attr.label(default = ":ast_grep.sh.tpl", allow_single_file = True),
    },
)
