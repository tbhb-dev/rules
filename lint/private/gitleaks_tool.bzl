# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Shared gitleaks wrapper: module base, local policy, and optional private rules.

Local policy has no extension. The wrapper attaches the module-provided base
in a temporary config, then redirects the private config's extension to it.
Private -> effective local -> base uses exactly two extension levels.
"""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _gitleaks_tool_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@BASE@@": ctx.file._base.short_path,
            "@@GITLEAKS@@": ctx.executable.gitleaks.short_path,
            "@@PREPARE@@": ctx.executable._prepare.short_path,
            "@@REQUIRED@@": "1" if ctx.attr.required else "",
            "@@SELF@@": script.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.file._base, ctx.executable._prepare, ctx.executable.gitleaks])
    runfiles = runfiles.merge(ctx.attr.gitleaks[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr._prepare[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_tool = rule(
    implementation = _gitleaks_tool_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = "gitleaks with the module base, local policy, and optional private config.",
    attrs = SHELL_ATTRS | {
        "gitleaks": attr.label(
            default = "@tbhb_rules_gitleaks//:gitleaks",
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The gitleaks executable.",
        ),
        "required": attr.bool(
            doc = "Require the private config and its canary rule.",
        ),
        "_base": attr.label(default = "//lint/gitleaks:base.toml", allow_single_file = True),
        "_prepare": attr.label(default = ":gitleaks_config", executable = True, cfg = "target"),
        "_runner": attr.label(
            default = ":gitleaks_tool.sh.tpl",
            allow_single_file = True,
        ),
    },
)
