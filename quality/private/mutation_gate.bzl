# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`mutation_gate_test` and the provider mutation runners return."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //quality:defs.bzl.
visibility("//quality/...")

# Most timed-out mutants, in percent of total, that still count as killed. A
# starved CPU makes tests time out, so past this share timeouts say the run
# was starved, not that the tests caught the mutants. One real run on 2 CPUs
# timed out 212 of 849 mutants, about 25%. The gate and both runners read this
# one value: the gate through its template, the runners through the
# environment variable below, which each requires.
MUTATION_MAX_TIMEOUT_PERCENT = 10
MUTATION_RUNNER_ENV = {"MUTATION_MAX_TIMEOUT_PERCENT": str(MUTATION_MAX_TIMEOUT_PERCENT)}

MutationReportInfo = provider(
    doc = """Mutation reports from a runner, in the format mutation_gate_test reads:
one `key=value` per line with the required integer keys total, killed,
lived, not_covered, timeout, errored, skipped and interrupted, plus
optional `mutant.<status>=<name>` lines for mutants not killed (in the
tool's own status names). A diff-scoped report adds `scope=diff`,
`selected` (equal to total), `changed_units` and `mutant.unmapped=<name>`
lines; mutation_gate.sh.tpl has the details.""",
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
        substitutions = {
            "@@MAX_TIMEOUT_PERCENT@@": str(MUTATION_MAX_TIMEOUT_PERCENT),
            "@@REPORTS@@": " ".join([shell.quote(r.short_path) for r in reports]),
            "@@REQUIRE_SCOPE@@": shell.quote(ctx.attr.require_scope),
        },
        is_executable = True,
    )
    executable, runfiles = shell_executable(ctx, script, ctx.runfiles(files = reports))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

mutation_gate_test = rule(
    implementation = _mutation_gate_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Passes only when every mutant in `reports` was killed, timed out or skipped.

A timed-out mutant counts as killed and stays listed; the gate prints how
many timed out, and appends that line to `$GITHUB_STEP_SUMMARY` when set.
It fails when timeouts exceed MUTATION_MAX_TIMEOUT_PERCENT of the mutants,
in the sum and in any one report, because a starved CPU makes tests time
out and that must not pass as kills.

Fails when any mutant lived, was not covered or errored, when a
run was interrupted, when the full-scope reports mutated nothing, and when
a report's counts don't add up exactly to its total (mutants a failed run
never checked, or mutants counted twice). A count above 1000000000, or a
listed mutant its verdict count denies, makes a report malformed, as does a
`mutant.not_checked` line (no run checked that mutant) or a `mutant.<status>`
line with a status no verdict names. The counts are summed over all reports.

A diff-scoped report (`scope=diff`) counts only the mutants of changed
code, and passes with none. Any `mutant.unmapped` line (the runner's
selection and the tool disagree) fails, and a diff report never satisfies
`require_scope = "full"`.""",
    attrs = SHELL_ATTRS | {
        "reports": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Targets giving MutationReportInfo, or report files.",
        ),
        "require_scope": attr.string(
            default = "any",
            values = ["any", "full"],
            doc = "`full` fails on diff-scoped reports: for gates on main and nightly runs.",
        ),
        "_runner": attr.label(
            default = ":mutation_gate.sh.tpl",
            allow_single_file = True,
        ),
    },
)
