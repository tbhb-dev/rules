# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Mutation testing of Go packages with gomutants: one cached report per package, and the gate."""

load(
    "@tbhb_rules//quality:defs.bzl",
    "MUTATION_CHANGES_ATTRS",
    "MutationReportInfo",
    "mutation_changes_slice",
    "mutation_gate_test",
)
load(":go_unit.bzl", "GO_TOOLCHAIN", "UNIT_ATTRS", "go_unit", "sdk_files", "tool_binary")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

# gomutants' 2s floor on the per-mutant timeout is too short for packages
# whose tests start slowly, and a mutant's run can stop at the first failing
# test. The flags attribute follows these, so a consumer's value wins.
_DEFAULT_FLAGS = ["--timeout-min=20s", "--test-flags=-failfast"]

def _gomutants_report_impl(ctx):
    unit = go_unit(ctx, "mutated")
    files = unit.files

    # The unit's slice of the change set, without the base: the same bytes
    # for every change set that touches none of the unit's files.
    unit_slice = mutation_changes_slice(ctx, files)

    gomutants = tool_binary(ctx.attr._gomutants, "gomutants.exe")
    report = ctx.actions.declare_file(ctx.label.name + ".txt")
    log = ctx.actions.declare_file(ctx.label.name + ".log")

    args = unit.args
    args.add("-gomutants", gomutants)
    args.add("-report", report)
    args.add("-log", log)
    if unit_slice:
        args.add("-changes", unit_slice)
    if ctx.attr.cpus:
        args.add("-workers", str(ctx.attr.cpus))
    args.add("--")
    args.add_all(_DEFAULT_FLAGS)
    args.add_all(ctx.attr.flags)
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset(
            [unit.manifest] + files + ctx.files.proxy + ([unit_slice] if unit_slice else []),
            transitive = [sdk_files(ctx)],
        ),
        tools = [ctx.attr._gomutants[DefaultInfo].files_to_run, gomutants],
        outputs = [report, log],
        mnemonic = "Gomutants",
        progress_message = "Mutation-testing %{label}",
        # gomutants times each mutant's tests against their recorded
        # durations; reserving the CPUs its workers use keeps that honest.
        execution_requirements = {"cpu:" + str(ctx.attr.cpus): ""} if ctx.attr.cpus else {},
    )
    return [
        DefaultInfo(files = depset([report, log] + ([unit_slice] if unit_slice else []))),
        MutationReportInfo(reports = depset([report])),
        OutputGroupInfo(changes = depset([unit_slice] if unit_slice else [])),
    ]

gomutants_report = rule(
    implementation = _gomutants_report_impl,
    doc = """Mutation-tests one Go package with gomutants, in one cached action.

The package is the one `tests` are in. The action copies its sources and
tests, the main-repository sources of every package they depend on
(through `deps` and `embed`), `data`, and go.mod and go.sum into a scratch
module, and runs gomutants on the package with the toolchain's go, offline
(modules come from `proxy`). gomutants runs a mutant against the tests of
its own package. So a change to a package reruns its unit and the units of
the packages that depend on it, and every other unit is a cache hit.

`changes` (quality's `changes` flag by default) sets the scope. With no
change set the package runs in full. With one, the action reads the unit's
slice of it: a full run when a change reaches its tests, data, go.mod,
go.sum, a package it depends on or a package-level declaration, or adds,
deletes or changes a file without changed lines; otherwise only the
functions the changed lines fall in, and nothing when no change reaches
the unit. Writes `<name>.txt` (MutationReportInfo), gomutants' log and the
slice (the `changes` output group).""",
    attrs = MUTATION_CHANGES_ATTRS | UNIT_ATTRS | {
        "cpus": attr.int(doc = "CPUs to reserve for the action (`cpu:N`) and gomutants workers to run; 0 for the defaults."),
        "flags": attr.string_list(doc = "More gomutants flags, such as `--timeout-coefficient=20`. They follow the defaults, so a later `--timeout-min` wins and `--test-flags=-failfast=false` turns fail-fast off."),
        "_gomutants": attr.label(
            default = Label("@tbhb_rules_gomutants//:gomutants"),
            executable = True,
            cfg = "exec",
        ),
        "_runner": attr.label(
            default = Label("//private/gomutants"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [GO_TOOLCHAIN],
)

def gomutants_test(name, tests, go_mod, go_sum = None, proxy = None, data = [], flags = [], cpus = 0, changes = None, require_scope = "any", **kwargs):
    """Mutation-tests Go packages with gomutants and fails unless every mutant was killed.

    Creates one gomutants_report per package that a test in `tests` is in,
    `<name>.<package>` (one cached gomutants run each), and `<name>`, a
    `mutation_gate_test` over their reports. Fails on a mutant that lived
    (its tests passed), one no test covers, a timeout, an infrastructure
    error, a failed run, a diff-scope selection that does not match what
    gomutants tested, and a full run that found nothing to mutate. A mutant
    that does not compile is skipped, not killed. Account for a mutant that
    must stay alive with a reviewed
    `// gomutants:disable-next-line <MUTATOR> reason="..."` directive.

    Args:
        name: Target name.
        tests: go_test targets; each package one is in is a unit.
        go_mod: The module's go.mod.
        go_sum: The module's go.sum, when it has requirements.
        proxy: A go_mod_proxy repository's `:proxy` target made from go.sum,
            when the module has requirements.
        data: Other files the tests read, in the module directory.
        flags: More gomutants flags, after the defaults
            `--timeout-min=20s --test-flags=-failfast`.
        cpus: CPUs to reserve per unit, and gomutants workers to run.
        changes: The change set; quality's `changes` flag when None.
        require_scope: `full` makes the gate fail on any diff-scope report,
            for main and nightly runs.
        **kwargs: Passed to the gate test.
    """
    by_package = {}
    for test in tests:
        package = native.package_relative_label(test).package
        by_package.setdefault(package, []).append(test)
    report_kwargs = {"changes": changes} if changes else {}
    reports = []
    for package, package_tests in sorted(by_package.items()):
        report = "{}.{}".format(name, package.replace("/", "_") or "_root")
        gomutants_report(
            name = report,
            tests = package_tests,
            go_mod = go_mod,
            go_sum = go_sum,
            proxy = proxy,
            data = data,
            flags = flags,
            cpus = cpus,
            # tests holds go_test targets.
            testonly = True,
            tags = kwargs.get("tags", []),
            visibility = ["//visibility:private"],
            **report_kwargs
        )
        reports.append(":" + report)
    mutation_gate_test(
        name = name,
        reports = reports,
        require_scope = require_scope,
        **kwargs
    )
