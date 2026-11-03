# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The golangci-lint parity oracle: the same linters run the ordinary way.

`golangci_lint_oracle` copies a Go module's files, collected through the
build graph by `go_srcs_aspect`, and runs golangci-lint over the copy with
the go command loading packages, offline (afakt's vendor-mode gate). Its
report has the aspect's format, so a parity test can compare the two.
"""

load("@rules_go//go:def.bzl", "GoArchive")

GoSrcsInfo = provider(
    doc = "Go sources of a target and the targets it depends on.",
    fields = {"srcs": "depset of File"},
)

def _go_srcs_aspect_impl(target, ctx):
    srcs = []
    if target.label.repo_name == "" and GoArchive in target:
        srcs = [f for f in getattr(ctx.rule.files, "srcs", []) if f.is_source]
    transitive = [
        dep[GoSrcsInfo].srcs
        for attr in ("deps", "embed")
        for dep in getattr(ctx.rule.attr, attr, []) or []
        if GoSrcsInfo in dep
    ]
    return [GoSrcsInfo(srcs = depset(srcs, transitive = transitive))]

go_srcs_aspect = aspect(
    implementation = _go_srcs_aspect_impl,
    attr_aspects = ["deps", "embed"],
)

def _oracle_impl(ctx):
    module_dir = ctx.file.go_mod.dirname
    files = depset(
        [ctx.file.go_mod, ctx.file.config] + ctx.files.data,
        transitive = [t[GoSrcsInfo].srcs for t in ctx.attr.srcs],
    )
    manifest = ctx.actions.declare_file(ctx.label.name + ".files")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add_all(files)
    ctx.actions.write(manifest, args)

    sdk = ctx.toolchains["@rules_go//go:toolchain"].sdk
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [
            ctx.executable._golangci_lint.path,
            ctx.executable._report.path,
            sdk.go.path,
            module_dir,
            ctx.file.config.path,
            manifest.path,
            out.path,
        ],
        inputs = depset(
            [manifest, sdk.go, sdk.root_file],
            transitive = [files, sdk.srcs, sdk.headers, sdk.tools, sdk.libs],
        ),
        outputs = [out],
        tools = [ctx.executable._golangci_lint, ctx.executable._report],
        mnemonic = "GolangciLintOracle",
        progress_message = "Running the golangci-lint oracle over %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

golangci_lint_oracle = rule(
    implementation = _oracle_impl,
    doc = "Runs golangci-lint over a module the ordinary way, offline, and writes a findings report.",
    attrs = {
        "config": attr.label(mandatory = True, allow_single_file = True),
        "data": attr.label_list(allow_files = True),
        "go_mod": attr.label(mandatory = True, allow_single_file = True),
        "srcs": attr.label_list(aspects = [go_srcs_aspect], doc = "Go targets whose sources make up the module."),
        "_golangci_lint": attr.label(
            default = "@multitool//tools/golangci-lint",
            executable = True,
            cfg = "exec",
        ),
        "_report": attr.label(default = "//private/report", executable = True, cfg = "exec"),
        "_runner": attr.label(
            default = ":oracle.sh",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = ["@rules_go//go:toolchain"],
)
