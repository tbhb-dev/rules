# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`gitleaks_tool`: gitleaks behind the private-config check.

With `required` set, the tool reads a private gitleaks config from the
`GITLEAKS_CONFIG_TOML` environment variable and fails closed: it refuses to
scan when the variable is unset or empty, or when the config has no rule
with the id `tbhb-private-canary`. The private config starts with
`[extend] path = ".gitleaks.toml"`, so it adds its rules to the committed
config, which the caller's `--config .gitleaks.toml` names. The tool passes
gitleaks the private config instead, and gitleaks reaches the committed one
through `[extend]`. Without `required`, it runs gitleaks unchanged.

`//lint:gitleaks_private_config` sets `required` for the default tool of
`gitleaks_test` and `gitleaks_history`.
"""

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _gitleaks_tool_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@GITLEAKS@@": ctx.executable.gitleaks.short_path,
            "@@REQUIRED@@": "1" if ctx.attr.required else "",
            "@@SELF@@": script.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [script, ctx.executable.gitleaks])
    runfiles = runfiles.merge(ctx.attr.gitleaks[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

gitleaks_tool = rule(
    implementation = _gitleaks_tool_impl,
    executable = True,
    doc = """gitleaks, requiring a private config from `GITLEAKS_CONFIG_TOML` when `required` is set.

The executable is a Bash script that the Bash runners of `gitleaks_test`
and `gitleaks_history` start, on Windows too; it isn't meant for
`bazel run`.""",
    attrs = {
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
        "_runner": attr.label(
            default = ":gitleaks_tool.sh.tpl",
            allow_single_file = True,
        ),
    },
)
