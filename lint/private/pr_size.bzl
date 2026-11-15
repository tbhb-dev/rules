# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The shared pull request size counter."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

visibility("//lint/...")

def _count_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@GIT@@": ctx.executable.git.short_path,
            "@@POLICY@@": ctx.file._policy.short_path,
            "@@SCC@@": ctx.executable.scc.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.scc, ctx.executable.git, ctx.file._policy])
    for tool in [ctx.attr.scc, ctx.attr.git]:
        runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

pr_size_count = rule(
    implementation = _count_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scc": attr.label(default = "@tbhb_rules_scc//:scc", executable = True, cfg = "target", allow_files = True),
        "_policy": attr.label(default = ":pr-size-exempt.txt", allow_single_file = True),
        "_runner": attr.label(default = ":pr_size.sh.tpl", allow_single_file = True),
    },
)

def _check_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {"@@COUNTER@@": ctx.executable.counter.short_path},
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.counter]).merge(ctx.attr.counter[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

pr_size = rule(
    implementation = _check_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "counter": attr.label(default = "//lint:pr_size_count", executable = True, cfg = "target"),
        "_runner": attr.label(default = ":pr_size_check.sh.tpl", allow_single_file = True),
    },
)
