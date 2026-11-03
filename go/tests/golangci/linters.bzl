# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The golangci-lint aspect, test and parity test over the parity fixture's config."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//:defs.bzl", "GolangciLintInfo", "golangci_lint_aspect_factory", "golangci_lint_test_factory")
load("//private:golangci_lint.bzl", "write_report_manifest")

fixture_lint = golangci_lint_aspect_factory(
    config = Label("//tests/golangci/fixture:.golangci.yml"),
    go_mod = Label("//tests/golangci/fixture:go.mod"),
)

fixture_lint_test = golangci_lint_test_factory(fixture_lint)

# A config golangci-lint rejects, for the proof that a run that does not
# complete fails the test.
broken_lint = golangci_lint_aspect_factory(
    config = Label("//tests/golangci/broken:.golangci.yml"),
)

broken_lint_test = golangci_lint_test_factory(broken_lint)

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
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [manifest, ctx.file.oracle, ctx.executable._merge], transitive_files = reports),
    )]

golangci_lint_parity_test = rule(
    implementation = _parity_test_impl,
    test = True,
    doc = "Passes when the aspect's reports over `srcs`, merged, equal the oracle's report.",
    attrs = {
        "oracle": attr.label(mandatory = True, allow_single_file = True),
        "srcs": attr.label_list(aspects = [fixture_lint], mandatory = True),
        "strip_prefix": attr.string(doc = "Prefix removed from the aspect's paths, making them module-relative."),
        "_merge": attr.label(
            default = "//private:golangci_lint_merge.sh",
            allow_single_file = True,
            executable = True,
            cfg = "target",
        ),
        "_runner": attr.label(default = ":parity_test.sh.tpl", allow_single_file = True),
    },
)
