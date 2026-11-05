# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`gobco_test`: requires every condition of one Go package to reach both outcomes, measured with gobco."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@tbhb_rules//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load(":go_unit.bzl", "GO_TOOLCHAIN", "UNIT_ATTRS", "go_unit", "sdk_files", "tool_binary")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

def _gobco_test_impl(ctx):
    unit = go_unit(ctx, "covered")
    gobco = tool_binary(ctx.attr._gobco, "gobco.exe")
    report = ctx.actions.declare_file(ctx.label.name + ".txt")

    args = unit.args
    args.add("-gobco", gobco)
    args.add("-report", report)
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset(
            [unit.manifest] + unit.files + ctx.files.proxy,
            transitive = [sdk_files(ctx)],
        ),
        tools = [ctx.attr._gobco[DefaultInfo].files_to_run, gobco],
        outputs = [report],
        mnemonic = "Gobco",
        progress_message = "Measuring condition coverage of %{label}",
    )

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._test_runner,
        output = script,
        substitutions = {
            "@@PACKAGE@@": shell.quote(unit.directory or "."),
            "@@REPORT@@": shell.quote(report.short_path),
        },
        is_executable = True,
    )
    executable, runfiles = shell_executable(ctx, script, ctx.runfiles(files = [report]))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gobco_test = rule(
    implementation = _gobco_test_impl,
    test = True,
    doc = """Fails when the tests of a Go package leave any condition outcome unreached.

Go's own coverage counts statements. gobco instruments every condition of
the package, and a run records whether each was true and false, so a branch
or an operand of `&&`/`||` no test reaches is found even when its line ran.
Each condition has two outcomes, and the required coverage is 100%: every
outcome of every condition. The requirement is fixed.

One gobco_test is one package, the one `tests` are in, and one cached build
action: it copies the package's sources and tests, the main-repository
sources of the packages they depend on (through `deps` and `embed`),
`data`, and go.mod and go.sum into a scratch module, and runs gobco on the
package with the toolchain's go, offline (modules come from `proxy`). A
change to a package reruns its target and those of the packages that depend
on it, and every other target is a cache hit. Declare one target next to each
package's go_test. gobco instruments one package per run, so a target for a
whole module would not be cached per package.

The test fails when any outcome is uncovered, and prints the uncovered
conditions as `file:line:column: condition "<code>" was ... but
never true|false`. A package with no conditions passes. The action fails,
and is not cached, when the package's tests fail under gobco or gobco
instruments nothing.

What gobco counts: the condition of every `if` and `for`, every case of an
expression switch (as `tag == case`, or the case expression of a tagless
one) and of a type switch, every comparison (`==`, `<`, `>=` and so on)
wherever it is, and each operand of `&&`, `||` and `!` on its own. That
includes the conditions gobco's own `-branch` mode counts, so one run
covers both. What it does not count: `select`, `default` clauses, and code
without conditions, such as a function with none or a statement no test
runs; pair it with Go's statement coverage.

Build constraints: gobco itself type-checks every file in the package
whatever its constraints, so the package's own sources and tests that a
`//go:build` line or a `_GOOS`/`_GOARCH` file name suffix excludes on the
platform the action runs on (with cgo off, as the tests run) are left out
of the scratch copy. A package with a Unix-only test file, or with files
for different platforms that declare the same names, is measured on each
platform with that platform's files; the conditions of an excluded file are
not counted there. The packages it depends on are loaded with their own
constraints applied. A test that starts a copy of itself with a
cleaned environment must pass `GOBCO_STATS` on, or the copy panics.

Platforms: the rule runs on Linux (x86_64 and arm64), macOS and Windows. The
gobco binary comes from the same pinned hub on each, and the gate runs
through the shell toolchain, as the other bash-based tests do on Windows.

The requirement is 100%, fixed, with no allowance: gobco has no way to mark
a condition as unreachable (no pragma, comment or ignore file), and this
rule adds no threshold, exclusion or ignore list. When a condition is
unreachable, restructure the code so it has none.""",
    attrs = SHELL_ATTRS | UNIT_ATTRS | {
        "_gobco": attr.label(
            default = Label("@tbhb_rules_gobco//:gobco"),
            executable = True,
            cfg = "exec",
        ),
        "_runner": attr.label(
            default = Label("//private/gobco"),
            executable = True,
            cfg = "exec",
        ),
        "_test_runner": attr.label(
            default = Label("//private:gobco_test.sh.tpl"),
            allow_single_file = True,
        ),
    },
    toolchains = [GO_TOOLCHAIN] + SHELL_TOOLCHAINS,
)
