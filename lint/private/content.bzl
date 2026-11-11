# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Reusable design checks and the runnable directory index writer."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//runtime:defs.bzl", "python_tool")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load(":tree_check.bzl", "tree_check_test")

visibility("//lint/...")

def _tool(name, testonly = True):
    python_tool(
        name = name + ".tool",
        main = Label(":content/check_design.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = testonly,
        visibility = ["//visibility:private"],
    )

def _args(forbidden_terms, max_lines):
    return ["--max-lines", str(max_lines)] + ["--forbidden-term=" + term for term in forbidden_terms]

def design_test(name, srcs, forbidden_terms = [], max_lines = 250, **kwargs):
    """Checks every design directory supplied in srcs with the pinned Python.

    Args:
        name: Test target name.
        srcs: Design READMEs, appendices and local link destinations.
        forbidden_terms: Whole words forbidden outside code, case-insensitively.
        max_lines: Maximum README lines; 0 disables the limit.
        **kwargs: Passed to tree_check_test, including data and strip_prefix.
    """
    _tool(name)
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":" + name + ".tool",
        tool_args = _args(forbidden_terms, max_lines),
        **kwargs
    )

def designs_index_test(name, srcs, out = "designs/README.md", forbidden_terms = [], max_lines = 250, **kwargs):
    """Checks the committed index, flat layout and each design together.

    Args:
        name: Test target name.
        srcs: All files under the designs directory, including its index.
        out: Workspace-relative index path (relative to strip_prefix if set).
        forbidden_terms: Words passed through to the design checker.
        max_lines: Maximum README lines; 0 disables the limit.
        **kwargs: Passed to tree_check_test.
    """
    _tool(name)
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":" + name + ".tool",
        tool_args = ["--index", out] + _args(forbidden_terms, max_lines),
        **kwargs
    )

def _index_impl(ctx):
    paths = []
    for file in ctx.files.srcs:
        if file.owner.repo_name != "":
            fail("designs_index srcs must belong to the main repository")
        paths.append(file.short_path)
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "".join([path + "\n" for path in sorted(paths)]))
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@ARGS@@": " ".join([shell.quote(arg) for arg in ["--index", ctx.attr.out] + _args(ctx.attr.forbidden_terms, ctx.attr.max_lines)]),
            "@@MANIFEST@@": manifest.short_path,
            "@@SELF@@": script.short_path,
            "@@TOOL@@": ctx.executable.tool.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [manifest, ctx.executable.tool] + ctx.files.srcs)
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_index = rule(
    implementation = _index_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "forbidden_terms": attr.string_list(),
        "max_lines": attr.int(default = 250),
        "out": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "tool": attr.label(executable = True, cfg = "target"),
        "_runner": attr.label(default = Label(":content/index.sh.tpl"), allow_single_file = True),
    },
)

def designs_index(name, srcs, out = "designs/README.md", forbidden_terms = [], max_lines = 250, **kwargs):
    """Creates a bazel run target that updates an index from declared files.

    The matching designs_index_test checks freshness and reuses the same
    per-design checks. The generated README has schema-compatible Readme frontmatter.

    Args:
        name: Runnable target name.
        srcs: All files under the designs directory (index optional).
        out: Workspace-relative output path, independent of the BUILD package.
        forbidden_terms: Words passed through to the design checker.
        max_lines: Maximum README lines; 0 disables the limit.
        **kwargs: Passed to the executable rule.
    """
    _tool(name, testonly = kwargs.get("testonly", False))
    _index(
        name = name,
        srcs = srcs,
        out = out,
        forbidden_terms = forbidden_terms,
        max_lines = max_lines,
        tool = ":" + name + ".tool",
        **kwargs
    )
