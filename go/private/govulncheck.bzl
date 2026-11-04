# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`govulncheck_test`: fails when a Go module's code can reach a known vulnerability, found with govulncheck."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@tbhb_rules//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load(":go_srcs.bzl", "go_srcs_aspect")
load(":go_unit.bzl", "GO_TOOLCHAIN", "MODULE_ATTRS", "go_module", "sdk_files", "tool_binary")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

def _govulncheck_impl(ctx):
    module = go_module(ctx, "scanned")
    govulncheck = tool_binary(ctx.attr._govulncheck, "govulncheck.exe")
    runner = ctx.executable._runner

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._script,
        output = script,
        substitutions = {
            "@@FLAGS@@": " ".join([shell.quote(f) for f in module.flags]),
            "@@GOVULNCHECK@@": shell.quote(govulncheck.short_path),
            "@@RUNNER@@": shell.quote(runner.short_path),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = [module.manifest, govulncheck, runner] + module.files + ctx.files.proxy,
        transitive_files = sdk_files(ctx),
    ).merge(ctx.attr._govulncheck[DefaultInfo].default_runfiles).merge(ctx.attr._runner[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_ATTRS = SHELL_ATTRS | MODULE_ATTRS | {
    "srcs": attr.label_list(
        aspects = [go_srcs_aspect],
        mandatory = True,
        doc = "go_library, go_binary and go_test targets of the module: every package to scan.",
    ),
    "_govulncheck": attr.label(
        default = Label("@tbhb_rules_govulncheck//:govulncheck"),
        executable = True,
        cfg = "exec",
    ),
    "_runner": attr.label(
        default = Label("//private/govulncheck"),
        executable = True,
        cfg = "exec",
    ),
    "_script": attr.label(
        default = Label("//private:govulncheck_test.sh.tpl"),
        allow_single_file = True,
    ),
}

_govulncheck_test = rule(
    implementation = _govulncheck_impl,
    test = True,
    attrs = _ATTRS,
    toolchains = [GO_TOOLCHAIN] + SHELL_TOOLCHAINS,
)

_govulncheck = rule(
    implementation = _govulncheck_impl,
    executable = True,
    attrs = _ATTRS,
    toolchains = [GO_TOOLCHAIN] + SHELL_TOOLCHAINS,
)

def govulncheck(name, srcs, go_mod, go_sum = None, proxy = None, data = [], **kwargs):
    """`bazel run` companion of govulncheck_test: the same scan, outside the test sandbox.

    Run it as `bazel run //path:name`, and add `-- --sarif=<file>` to write
    the SARIF report to a file (a relative path is from the directory `bazel
    run` was started in). Exits 1 when the code calls a vulnerable function.
    It is testonly, as `srcs` may hold go_test targets.

    Args:
        name: Target name.
        srcs: go_library, go_binary and go_test targets of the module.
        go_mod: The module's go.mod.
        go_sum: The module's go.sum, when it has requirements.
        proxy: A go_mod_proxy repository's `:proxy` target made from go.sum,
            when the module has requirements.
        data: Other files the packages read, in the module directory.
        **kwargs: Passed to the rule.
    """
    _govulncheck(
        name = name,
        srcs = srcs,
        go_mod = go_mod,
        go_sum = go_sum,
        proxy = proxy,
        data = data,
        testonly = True,
        **kwargs
    )

def govulncheck_test(name, srcs, go_mod, go_sum = None, proxy = None, data = [], tags = [], **kwargs):
    """Fails when the code of a Go module can reach a known vulnerability.

    govulncheck loads the module's packages in source mode, against its
    go.mod and go.sum, and follows the calls from them into the modules they
    use and the standard library. A vulnerability in a module the code
    requires but never calls, or in a package it imports but whose
    vulnerable function nothing calls, is only reported, and does not fail
    the test. Any call that can reach a vulnerable function does, and the
    test log holds govulncheck's own text report: the OSV ID, the module and
    the fixed version, and a call stack from the module's code. Test files
    are copied but not analyzed (govulncheck's `-test` is off): a
    vulnerability only a test can reach does not fail it. The standard
    library is the toolchain's, so a Go release with a fix is a reason to
    move the SDK.

    One test is one module, as the findings are about the module's
    dependency graph: `srcs` lists the packages to scan, as the
    go_library, go_binary and go_test targets that other checks of the
    module take, and the test copies their main-repository sources, the
    sources of the packages they depend on, `data`, and go.mod and go.sum
    into a scratch module. Packages no target in `srcs` reaches are not
    scanned. Go runs there with the toolchain's go, and modules come from
    `proxy`, a go_mod_proxy repository made from go.sum, so a version go.sum
    does not list cannot be loaded. Only govulncheck's fetch of the
    vulnerability database (https://vuln.go.dev) uses the network, through
    the test's `HTTPS_PROXY` when it sets one.

    Advisories are published without any input changing, so the test is
    tagged `requires-network`, `external` (never cached) and `manual` (not
    part of `//...`): run it explicitly, on a schedule or in CI with
    `bazel test //path:name`, or use the `govulncheck` rule for `bazel run`.

    SARIF: the test also writes the scan as SARIF 2.1.0 to
    `govulncheck.sarif` in `$TEST_UNDECLARED_OUTPUTS_DIR`, whether or not the
    scan found anything. Bazel puts it at
    `$(bazel info bazel-testlogs)/<package>/<name>/test.outputs/govulncheck.sarif`, in
    `outputs.zip` there under `--zip_undeclared_test_outputs`, for GitHub's
    `github/codeql-action/upload-sarif` (give each test its own `category`).
    `bazel run` writes it where `--sarif=` says. Locations in the module's
    own files are made relative to the repository root, so they match a
    module whose go.mod is not at the root. A scan that fails (a
    vulnerability database that cannot be fetched, a package that does not
    load) writes none.

    Platforms: Linux (x86_64 and arm64), macOS and Windows. The govulncheck
    binary comes from the same pinned hub on each, and the gate runs through
    the shell toolchain, as the other bash-based tests do on Windows.

    Args:
        name: Target name.
        srcs: go_library, go_binary and go_test targets of the module.
        go_mod: The module's go.mod.
        go_sum: The module's go.sum, when it has requirements.
        proxy: A go_mod_proxy repository's `:proxy` target made from go.sum,
            when the module has requirements.
        data: Other files the packages read (embedded files), in the module
            directory.
        tags: More tags.
        **kwargs: Passed to the test rule.
    """
    _govulncheck_test(
        name = name,
        srcs = srcs,
        go_mod = go_mod,
        go_sum = go_sum,
        proxy = proxy,
        data = data,
        tags = ["requires-network", "external", "manual"] + tags,
        **kwargs
    )
