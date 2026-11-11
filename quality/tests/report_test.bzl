# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Report assertions shared by the mutation runner e2e proofs."""

load("//quality:defs.bzl", "MutationReportInfo")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

def _mutation_report_file_impl(ctx):
    return [DefaultInfo(files = ctx.attr.report[MutationReportInfo].reports)]

mutation_report_file = rule(
    implementation = _mutation_report_file_impl,
    attrs = {"report": attr.label(providers = [MutationReportInfo])},
)

def _mutation_report_test_impl(ctx):
    reports = ctx.attr.report[MutationReportInfo].reports.to_list()
    if len(reports) != 1:
        fail("expected one mutation report")
    report = reports[0]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = """#!/usr/bin/env bash
set -euo pipefail
report="{report}"
cat "$report"
grep -qx 'scope={scope}' "$report"
total=$(sed -n 's/^total=//p' "$report")
{count_check}
{diff_check}
""".format(
            report = report.short_path,
            scope = ctx.attr.scope,
            count_check = '[[ "$total" == 0 ]]' if ctx.attr.empty else "((total > 0))",
            diff_check = "grep -qx 'selected='\"$total\" \"$report\"\ngrep -qx 'changed_units={}' \"$report\"".format(0 if ctx.attr.empty else 1) if ctx.attr.scope == "diff" else "",
        ),
        is_executable = True,
    )
    executable, runfiles = shell_executable(ctx, script, ctx.runfiles(files = reports))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

mutation_report_test = rule(
    implementation = _mutation_report_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "empty": attr.bool(),
        "report": attr.label(providers = [MutationReportInfo]),
        "scope": attr.string(values = ["full", "diff"]),
    },
)
