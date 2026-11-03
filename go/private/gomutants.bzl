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
load(":go_srcs.bzl", "GoSrcsInfo", "go_srcs_aspect")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

_GO_TOOLCHAIN = "@rules_go//go:toolchain"

def _dirname(path):
    return path.rpartition("/")[0]

def _gomutants_binary(target):
    """The gomutants executable itself, not the hub's Bash shim on Windows."""
    for f in target[DefaultInfo].default_runfiles.files.to_list():
        if f.basename == "gomutants.exe":
            return f
    return target[DefaultInfo].files_to_run.executable

def _gomutants_report_impl(ctx):
    prefix = ctx.file.go_mod.short_path[:-len("go.mod")]
    directories = {t.label.package: True for t in ctx.attr.tests}
    if len(directories) != 1:
        fail("tests must all be in one package; they are in {}".format(sorted(directories)))
    directory = list(directories)[0]
    if prefix and not (directory + "/").startswith(prefix):
        fail("{} is not in the module directory {}".format(directory, prefix))
    pkg = directory[len(prefix):] or "."

    # The package's own sources are mutated, against its tests; the sources
    # of the packages it depends on are deps.
    entries = []
    for f in depset(transitive = [t[GoSrcsInfo].srcs for t in ctx.attr.tests]).to_list():
        role = "dep"
        if _dirname(f.short_path) == directory:
            role = "test" if f.basename.endswith("_test.go") else "mut"
        entries.append((role, f))
    if not [f for role, f in entries if role == "mut"]:
        fail("the tests in {} reach no source of their own package".format(directory or "."))
    entries += [("data", f) for f in ctx.files.data]
    entries.append(("mod", ctx.file.go_mod))
    if ctx.file.go_sum:
        entries.append(("mod", ctx.file.go_sum))
    for _, f in entries:
        if f.owner.repo_name != "":
            fail("{} is from repository @{}; only files of the main repository can be mutated".format(f.short_path, f.owner.repo_name))
        if not f.short_path.startswith(prefix):
            fail("{} is not in the module directory {}".format(f.short_path, prefix or "."))
    files = [f for _, f in entries]

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "".join([
        "{}\t{}\t{}\n".format(role, f.path, f.short_path[len(prefix):])
        for role, f in entries
    ]))

    # The unit's slice of the change set, without the base: the same bytes
    # for every change set that touches none of the unit's files.
    unit_slice = mutation_changes_slice(ctx, files)

    sdk = ctx.toolchains[_GO_TOOLCHAIN].sdk
    sdk_files = depset([sdk.go, sdk.root_file], transitive = [sdk.srcs, sdk.headers, sdk.tools, sdk.libs])
    gomutants = _gomutants_binary(ctx.attr._gomutants)
    report = ctx.actions.declare_file(ctx.label.name + ".txt")
    log = ctx.actions.declare_file(ctx.label.name + ".log")

    args = ctx.actions.args()
    args.add("-gomutants", gomutants)
    args.add("-go", sdk.go)
    args.add("-manifest", manifest)
    args.add("-prefix", prefix)
    args.add("-pkg", pkg)
    args.add("-report", report)
    args.add("-log", log)
    if unit_slice:
        args.add("-changes", unit_slice)
    if ctx.attr.proxy:
        roots = [f for f in ctx.files.proxy if f.basename == "go_mod_proxy.root"]
        if len(roots) != 1:
            fail("proxy must be a go_mod_proxy repository's :proxy target")
        args.add("-proxy", roots[0].dirname)
    if ctx.attr.cpus:
        args.add("-workers", str(ctx.attr.cpus))
    args.add("--")
    args.add_all(ctx.attr.flags)
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset(
            [manifest] + files + ctx.files.proxy + ([unit_slice] if unit_slice else []),
            transitive = [sdk_files],
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
    attrs = MUTATION_CHANGES_ATTRS | {
        "cpus": attr.int(doc = "CPUs to reserve for the action (`cpu:N`) and gomutants workers to run; 0 for the defaults."),
        "data": attr.label_list(
            allow_files = True,
            doc = "Other files the tests read (testdata, embedded files), in the module directory.",
        ),
        "flags": attr.string_list(doc = "More gomutants flags, such as `--timeout-coefficient=20`."),
        "go_mod": attr.label(mandatory = True, allow_single_file = ["go.mod"]),
        "go_sum": attr.label(allow_single_file = ["go.sum"], doc = "The module's go.sum, when it has requirements."),
        "proxy": attr.label(
            allow_files = True,
            doc = "The `:proxy` target of a go_mod_proxy repository made from go.sum, when the module has requirements.",
        ),
        "tests": attr.label_list(
            aspects = [go_srcs_aspect],
            mandatory = True,
            doc = "go_test targets of one package, which is mutated against them.",
        ),
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
    toolchains = [_GO_TOOLCHAIN],
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
        flags: More gomutants flags.
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
