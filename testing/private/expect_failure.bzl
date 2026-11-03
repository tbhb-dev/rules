# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`expect_failure_test`: a test that passes when another test fails for a stated reason."""

load("@bazel_skylib//lib:shell.bzl", "shell")

# Internal: consumers load //testing:defs.bzl.
visibility("//testing/...")

def _expect_failure_impl(ctx):
    if not ctx.attr.pattern:
        fail("pattern must not be empty: a failure for any reason would pass")

    wrapped = ctx.attr.test[DefaultInfo].files_to_run.executable
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@PATTERN@@": shell.quote(ctx.attr.pattern),
            "@@TEST@@": wrapped.short_path,
        },
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [wrapped]).merge(ctx.attr.test[DefaultInfo].default_runfiles)

    environment = {}
    inherited = []
    if RunEnvironmentInfo in ctx.attr.test:
        environment = dict(ctx.attr.test[RunEnvironmentInfo].environment)
        inherited = list(ctx.attr.test[RunEnvironmentInfo].inherited_environment)
    return [
        DefaultInfo(executable = script, runfiles = runfiles),
        RunEnvironmentInfo(environment = environment, inherited_environment = inherited),
    ]

expect_failure_test = rule(
    implementation = _expect_failure_impl,
    test = True,
    doc = """Passes when `test` fails and its output matches `pattern`.

For failure proofs: a check that must reject bad input is only proven by a
test that runs it on bad input and requires the rejection, for the right
reason. This test runs the wrapped test's executable in its own runfiles,
with the wrapped test's `env`, a scratch `TEST_TMPDIR` and `HOME` of its own,
and without the result files Bazel collects (test.xml and the like), so it
cannot overwrite this test's own. It passes only when the wrapped test exits
non-zero and its combined output matches `pattern`; otherwise it fails and
prints the exit status and the output.

Bazel exposes no provider for a test's `args`, so the wrapped test's `args`
are not forwarded: set them on this target instead. Tag the wrapped test
`manual`, so `bazel test //...` does not run it on its own and report the
expected failure as a failure.""",
    attrs = {
        "pattern": attr.string(
            mandatory = True,
            doc = "Extended regular expression the wrapped test's output must match.",
        ),
        "test": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "The test that must fail.",
        ),
        "_runner": attr.label(
            default = ":expect_failure.sh.tpl",
            allow_single_file = True,
        ),
    },
)
