# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Mutation testing of Go packages with gomutants: one cached report per package, and the gate."""

load(
    "@tbhb_rules//quality:defs.bzl",
    "MUTATION_CHANGES_ATTRS",
    "MutationReportInfo",
    "mutation_changes_slice",
    "mutation_gate_test",
    "mutation_os_constraints",
)
load(":go_unit.bzl", "GO_TOOLCHAIN", "UNIT_ATTRS", "go_unit", "sdk_files", "tool_binary")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

# gomutants' 2s floor on the per-mutant timeout is too short for packages
# whose tests start slowly, and a mutant's run can stop at the first failing
# test. The flags attribute follows these, so a consumer's value wins.
_DEFAULT_FLAGS = ["--timeout-min=20s", "--test-flags=-failfast"]

# A timed-out mutant is unstable, so a slow Windows runner fails the gate when
# the ceiling (the baseline times the coefficient) is too tight. A Windows
# execution platform gets a higher floor and ceiling; a timeout still never
# counts as killed.
_WINDOWS_DEFAULT_FLAGS = ["--timeout-min=60s", "--timeout-coefficient=40", "--test-flags=-failfast"]

def default_flags(exec_goos):
    """The default gomutants flags for the platform the action runs on.

    Args:
        exec_goos: The Go SDK's goos, the OS of the execution platform.

    Returns:
        The flags that come before the rule's `flags`.
    """
    return _WINDOWS_DEFAULT_FLAGS if exec_goos == "windows" else _DEFAULT_FLAGS

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

    # The Go SDK is resolved for the execution platform, where the action
    # runs, so its goos is the exec OS (the toolchain's own goos is the target's).
    args.add_all(default_flags(ctx.toolchains[GO_TOOLCHAIN].sdk.goos))
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

def gomutants_test(name, tests, go_mod, go_sum = None, proxy = None, data = [], flags = [], cpus = 0, changes = None, require_scope = "any", mutation_oses = None, diff_ignore = [], **kwargs):
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
            `--timeout-min=20s --test-flags=-failfast`, or on a Windows
            execution platform
            `--timeout-min=60s --timeout-coefficient=40 --test-flags=-failfast`.
        cpus: CPUs to reserve per unit, and gomutants workers to run.
        changes: The change set; quality's `changes` flag when None.
        require_scope: `full` makes the gate fail on any diff-scope report,
            for main and nightly runs.
        diff_ignore: Repository-relative paths to omit from diff selection,
            exactly as spelled in the change set. A trailing `/` matches
            every path below that directory; no other glob syntax applies.
            Empty keeps the existing selection. Files remain action inputs.
            A repository using this must run full-scope mutation elsewhere,
            such as a scheduled run without a change set. A listed file's
            change that alters a verdict is caught only by that full run.
        mutation_oses: None preserves every OS the target already runs on.
            Otherwise a list of linux, macos, windows: reports and gate run
            only on a listed OS that also meets target_compatible_with.
            An empty list skips all OSes; unknown names fail at load time.
        **kwargs: Passed to the gate test; target_compatible_with is applied
            to the reports and the gate.
    """
    if mutation_oses != None:
        kwargs["target_compatible_with"] = kwargs.get("target_compatible_with", []) + mutation_os_constraints(mutation_oses)
    by_package = {}
    for test in tests:
        package = native.package_relative_label(test).package
        by_package.setdefault(package, []).append(test)
    report_kwargs = {"changes": changes} if changes else {}
    if kwargs.get("target_compatible_with") != None:
        report_kwargs["target_compatible_with"] = kwargs.get("target_compatible_with")
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
            diff_ignore = diff_ignore,
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
