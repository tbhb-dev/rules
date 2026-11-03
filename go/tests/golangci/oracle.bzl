# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The golangci-lint parity oracle: the same linters run the ordinary way.

`golangci_lint_oracle` copies a Go module's files, collected through the
build graph by `go_srcs_aspect`, and runs golangci-lint over the copy with
the go command loading packages, offline (afakt's vendor-mode gate; with
`proxy`, modules come from a go_mod_proxy directory instead of vendor/).
Its report has the aspect's format, and a test made by
`golangci_lint_parity_test_factory` compares the two.

Test infrastructure of tbhb_rules_go, loaded by its e2e smoke module too;
not public API.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@tbhb_rules//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load("//:defs.bzl", "GolangciLintInfo")
load("//private:go_srcs.bzl", "GoSrcsInfo", "go_srcs_aspect")
load("//private:golangci_lint.bzl", "action_binary", "write_report_manifest")

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

    proxy = ""
    if ctx.attr.proxy:
        roots = [f for f in ctx.files.proxy if f.basename == "go_mod_proxy.root"]
        if len(roots) != 1:
            fail("proxy must be a go_mod_proxy repository's :proxy target")
        proxy = roots[0].dirname

    sdk = ctx.toolchains["@rules_go//go:toolchain"].sdk
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [
            action_binary(ctx).path,
            ctx.executable._report.path,
            sdk.go.path,
            module_dir,
            ctx.file.config.path,
            manifest.path,
            out.path,
            proxy,
        ],
        inputs = depset(
            [manifest, sdk.go, sdk.root_file] + ctx.files.proxy,
            transitive = [files, sdk.srcs, sdk.headers, sdk.tools, sdk.libs],
        ),
        outputs = [out],
        tools = [action_binary(ctx), ctx.executable._report],
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
        "proxy": attr.label(allow_files = True, doc = "A go_mod_proxy repository's `:proxy`, for a module with dependencies and no vendor/."),
        "srcs": attr.label_list(aspects = [go_srcs_aspect], doc = "Go targets whose sources make up the module."),
        "_golangci_lint": attr.label(
            default = Label("@tbhb_rules_golangci_lint//:golangci-lint"),
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
        "_report": attr.label(default = Label("//private/report"), executable = True, cfg = "exec"),
        "_runner": attr.label(
            default = Label(":oracle_runner"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = ["@rules_go//go:toolchain"],
)

def _parity_test_impl(ctx):
    reports = depset(transitive = [t[GolangciLintInfo].reports for t in ctx.attr.srcs])
    manifest = write_report_manifest(ctx, reports)
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@MANIFEST@@": manifest.short_path,
            "@@MERGE@@": ctx.executable._merge.short_path,
            "@@ORACLE@@": ctx.file.oracle.short_path,
            "@@STRIP@@": shell.quote(ctx.attr.strip_prefix),
        },
        is_executable = True,
    )
    executable, runfiles = shell_executable(
        ctx,
        script,
        ctx.runfiles(files = [manifest, ctx.file.oracle, ctx.executable._merge], transitive_files = reports),
    )
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

def golangci_lint_parity_test_factory(aspect):
    """Makes a test rule comparing `aspect`'s reports with an oracle's.

    Args:
        aspect: An aspect from golangci_lint_aspect_factory.

    Returns:
        A test rule with `srcs` (Go targets), `oracle` (a
        golangci_lint_oracle) and `strip_prefix`.
    """
    return rule(
        implementation = _parity_test_impl,
        test = True,
        toolchains = SHELL_TOOLCHAINS,
        doc = "Passes when the aspect's reports over `srcs`, merged, equal the oracle's report.",
        attrs = SHELL_ATTRS | {
            "oracle": attr.label(mandatory = True, allow_single_file = True),
            "srcs": attr.label_list(aspects = [aspect], mandatory = True),
            "strip_prefix": attr.string(doc = "Prefix removed from the aspect's paths, making them module-relative."),
            "_merge": attr.label(
                default = Label("//private:golangci_lint_merge.sh"),
                allow_single_file = True,
                executable = True,
                cfg = "target",
            ),
            "_runner": attr.label(default = Label(":parity_test.sh.tpl"), allow_single_file = True),
        },
    )
