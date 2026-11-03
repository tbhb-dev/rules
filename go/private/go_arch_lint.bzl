# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`go_arch_lint_test`: go-arch-lint's import contracts over a Go module.

go-arch-lint with `allow.deepScan: false` parses the import clauses of the
module's files and reads go.mod for the module path; it runs no go command
and needs no module cache, export data or packages driver. So this is one
whole-module test over a copy of the module's sources, not a per-package
aspect: the contracts are graph-wide and a run takes milliseconds.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load(":go_srcs.bzl", "GoSrcsInfo", "go_srcs_aspect")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

def _go_arch_lint_test_impl(ctx):
    srcs = depset(transitive = [t[GoSrcsInfo].srcs for t in ctx.attr.srcs])
    if not srcs:
        fail("srcs reach no Go source of the main repository")

    # The module directory, as a short-path prefix ("" at the root).
    prefix = ctx.file.go_mod.short_path[:-len("go.mod")]
    files = [ctx.file.go_mod, ctx.file.config] + srcs.to_list()
    for f in files:
        if not f.short_path.startswith(prefix):
            fail("{} is not in the module directory {}".format(f.short_path, prefix or "."))

    manifest = ctx.actions.declare_file(ctx.label.name + ".files")
    ctx.actions.write(manifest, "".join([
        "{}\t{}\n".format(f.short_path, f.short_path[len(prefix):])
        for f in files
    ]))
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@ARGS@@": " ".join([shell.quote(a) for a in ctx.attr.args]),
            "@@CONFIG@@": shell.quote(ctx.file.config.short_path[len(prefix):]),
            "@@MANIFEST@@": manifest.short_path,
            "@@TOOL@@": ctx.executable.tool.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [manifest, ctx.executable.tool] + files)
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

go_arch_lint_test = rule(
    implementation = _go_arch_lint_test_impl,
    test = True,
    doc = """Fails when the module breaks the contracts of a go-arch-lint config.

The test copies `go_mod`, `config` and the main-repository Go sources that
`srcs` reach (through `deps` and `embed`) to a scratch tree laid out
relative to go.mod's directory, and runs `go-arch-lint check` there. The
config must set `allow.deepScan: false`: deep scanning runs the go command,
which the test does not have. The test fails when no Go file reaches the
copy, and go-arch-lint fails on a file that belongs to no component, so a
package `srcs` reach cannot escape the contracts. A package `srcs` does not
reach is not checked: list every binary and test, or every package.""",
    attrs = {
        "args": attr.string_list(doc = "Extra `go-arch-lint check` flags, such as `--max-warnings`."),
        "config": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The go-arch-lint config (`.go-arch-lint.yml`), in the module directory.",
        ),
        "go_mod": attr.label(mandatory = True, allow_single_file = ["go.mod"]),
        "srcs": attr.label_list(
            aspects = [go_srcs_aspect],
            mandatory = True,
            doc = "Go targets whose main-repository sources make up the module.",
        ),
        "tool": attr.label(
            default = Label("//private:go_arch_lint"),
            executable = True,
            allow_files = True,
            cfg = "target",
            doc = "The go-arch-lint binary.",
        ),
        "_runner": attr.label(
            default = Label("//private:go_arch_lint.sh.tpl"),
            allow_single_file = True,
        ),
    },
)
