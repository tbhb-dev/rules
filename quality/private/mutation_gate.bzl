# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`mutation_gate_test` and the provider mutation runners return."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //quality:defs.bzl.
visibility("//quality/...")

MutationReportInfo = provider(
    doc = """Mutation reports from a runner, in the format mutation_gate_test reads:
one `key=value` per line with the required integer keys total, killed,
skipped, survived, timeout, suspicious, no_tests, segfault and interrupted,
plus optional `mutant.<status>=<name>` lines for mutants not killed.""",
    fields = {"reports": "depset of report Files"},
)

def _mutation_gate_impl(ctx):
    reports = []
    for target in ctx.attr.reports:
        if MutationReportInfo in target:
            reports.extend(target[MutationReportInfo].reports.to_list())
        else:
            reports.extend(target.files.to_list())
    if not reports:
        fail("reports gives no report files")

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {"@@REPORTS@@": " ".join([shell.quote(r.short_path) for r in reports])},
        is_executable = True,
    )
    executable, runfiles = shell_executable(ctx, script, ctx.runfiles(files = reports))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

mutation_gate_test = rule(
    implementation = _mutation_gate_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Passes only when every mutant in `reports` was killed or skipped.

Fails when any mutant survived, timed out, was suspicious, had no tests or
crashed, when a run was interrupted, when nothing was mutated, and when the
counts don't add up to the total (mutants a failed run never checked). The
counts are summed over all reports.""",
    attrs = SHELL_ATTRS | {
        "reports": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Targets giving MutationReportInfo, or report files.",
        ),
        "_runner": attr.label(
            default = ":mutation_gate.sh.tpl",
            allow_single_file = True,
        ),
    },
)
