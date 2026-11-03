# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The executable behind the `golangci_fmt` formatter.

`golangci-lint fmt` runs the formatters a .golangci.yml enables (gci,
gofumpt, goimports, golines, ...). gci and goimports run the go command,
so this wraps golangci-lint with the rules_go SDK's go on PATH: the
formatter needs no Go installation and formats the same everywhere.
"""

# Internal: consumers load //:defs.bzl or use //:golangci_fmt.
visibility(["//", "//private/...", "//tests/..."])

def _golangci_fmt_tool_impl(ctx):
    sdk = ctx.toolchains["@rules_go//go:toolchain"].sdk
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        substitutions = {
            "@@GO@@": sdk.go.short_path,
            "@@GOLANGCI_LINT@@": ctx.executable.golangci_lint.short_path,
            "@@SELF@@": script.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = [ctx.executable.golangci_lint, sdk.go, sdk.root_file],
        transitive_files = depset(transitive = [sdk.srcs, sdk.headers, sdk.tools, sdk.libs]),
    ).merge(ctx.attr.golangci_lint[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

golangci_fmt_tool = rule(
    implementation = _golangci_fmt_tool_impl,
    executable = True,
    doc = "golangci-lint with the Go SDK's go on PATH, for `golangci-lint fmt`.",
    attrs = {
        "golangci_lint": attr.label(
            default = "@multitool//tools/golangci-lint",
            executable = True,
            cfg = "target",
        ),
        "_template": attr.label(
            default = ":golangci_fmt.sh.tpl",
            allow_single_file = True,
        ),
    },
    toolchains = ["@rules_go//go:toolchain"],
)
