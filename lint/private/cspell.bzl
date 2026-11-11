# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`cspell_test`: spelling over a copy of the tree, with a pinned cspell."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _cspell_tool_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@CONFIG@@": ctx.file._config.short_path,
            "@@ROOT@@": "../" * (len(script.short_path.split("/")) - 1),
            "@@TOOL@@": ctx.executable.tool.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.tool, ctx.file._config, ctx.file._words])
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_cspell_tool = rule(
    implementation = _cspell_tool_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "tool": attr.label(executable = True, cfg = "target", allow_single_file = True, mandatory = True),
        "_config": attr.label(default = "//lint/vocabulary:cspell.config.cjs", allow_single_file = True),
        "_runner": attr.label(default = ":cspell.sh.tpl", allow_single_file = True),
        "_words": attr.label(default = "//lint/vocabulary:words.txt", allow_single_file = True),
    },
)

def cspell_test(name, srcs, config = None, data = [], tool = Label("//lint/private/cspell"), **kwargs):
    """Checks spelling in every file of `srcs` with cspell.

    cspell comes from npm, installed by rules_js from tbhb_rules' own pnpm
    lock under a private hub name, so a consumer needs no npm or pnpm setup
    and its own rules_js hubs never meet this one. It runs on the default
    rules_nodejs toolchain, which the root module chooses; cspell 10 needs
    Node 22.18 or newer.

    Every file is checked, dotfiles included; leave files out with the
    config's `ignorePaths`. The bundled dictionaries (golang and python
    among them) and the shared `//lint/vocabulary:words.txt` are available
    to the config; project word lists go in `data`. A tree with no files
    to check fails, and so does a run whose summary reports no file checked.

    Args:
        name: Target name.
        srcs: Files to check, usually a `repo_files` target.
        config: A cspell config such as `.cspell.jsonc`.
        data: Files the config names, such as dictionary word lists.
        tool: The cspell binary.
        **kwargs: Passed to `tree_check_test`.
    """

    # The js_binary launcher refuses to start outside its own `bazel run` or
    # test unless BAZEL_BINDIR is set; "." is its documented value for a
    # program that is not a build action, as here, where the test's runner
    # starts it in the copy of the tree.
    env = dict(kwargs.pop("env", {}))
    env.setdefault("BAZEL_BINDIR", ".")
    _cspell_tool(
        name = name + "_tool",
        tool = tool,
        testonly = True,
    )
    tree_check_test(
        name = name,
        env = env,
        srcs = srcs,
        config = config,
        data = data,
        tool = ":" + name + "_tool",
        tool_args = ["{config}" if config else ""],
        # cspell's summary counts the files it read; zero means it saw nothing.
        output_guard = "Files checked: [1-9]",
        **kwargs
    )
