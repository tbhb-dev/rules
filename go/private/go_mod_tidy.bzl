# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`go_mod_tidy_test`: `go mod tidy -diff` and `go mod verify`, offline."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@tbhb_rules//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

_GO_TOOLCHAIN = "@rules_go//go:toolchain"

def _go_mod_tidy_test_impl(ctx):
    # The module directory, as a short-path prefix ("" at the root).
    prefix = ctx.file.go_mod.short_path[:-len("go.mod")]
    files = [ctx.file.go_mod, ctx.file.go_sum] + ctx.files.srcs
    for f in files:
        if not f.short_path.startswith(prefix):
            fail("{} is not in the module directory {}".format(f.short_path, prefix or "."))
    roots = [f for f in ctx.files.proxy if f.basename == "go_mod_proxy.root"]
    if len(roots) != 1:
        fail("proxy must be a go_mod_proxy repository's :proxy target")
    manifest = ctx.actions.declare_file(ctx.label.name + ".files")
    ctx.actions.write(manifest, "".join([
        "{}\t{}\n".format(f.short_path, f.short_path[len(prefix):])
        for f in files
    ]))

    sdk = ctx.toolchains[_GO_TOOLCHAIN].sdk
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@GO@@": sdk.go.short_path,
            "@@MANIFEST@@": manifest.short_path,
            "@@PROXY@@": shell.quote(roots[0].short_path.rpartition("/")[0]),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = [manifest, sdk.go, sdk.root_file] + files + ctx.files.proxy,
        transitive_files = depset(transitive = [sdk.srcs, sdk.headers, sdk.tools, sdk.libs]),
    )
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

go_mod_tidy_test = rule(
    implementation = _go_mod_tidy_test_impl,
    test = True,
    doc = """Fails when `go mod tidy` would change go.mod or go.sum, or when
`go mod verify` finds a module that does not match go.sum.

The test copies the module (`go_mod`, `go_sum` and `srcs`, laid out
relative to go.mod's directory) and runs the SDK's go command over the
copy with a fresh module cache and `GOPROXY` set to `proxy`, a directory
of modules made by the `go_mod_proxy` extension from the same go.sum: no
network. A module go.sum does not list cannot be fetched, so a missing
requirement fails as untidy.""",
    attrs = SHELL_ATTRS | {
        "go_mod": attr.label(mandatory = True, allow_single_file = ["go.mod"]),
        "go_sum": attr.label(mandatory = True, allow_single_file = ["go.sum"]),
        "proxy": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "The `:proxy` target of a go_mod_proxy repository made from this go.sum.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "The module's Go sources (and embedded files): what tidy reads imports from.",
        ),
        "_runner": attr.label(
            default = Label("//private:go_mod_tidy.sh.tpl"),
            allow_single_file = True,
        ),
    },
    toolchains = [_GO_TOOLCHAIN] + SHELL_TOOLCHAINS,
)
