# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`go_deadcode_test`: deadcode over Go targets, through the static driver.

deadcode builds SSA for the whole program and reports the functions no
`main` (and, with `test`, no test) reaches. Here it loads the program
through the same static GOPACKAGESDRIVER the golangci-lint aspect uses, in
a build action, so it needs no go command, module cache or network, and its
report is cached like any action output.
"""

load("@rules_go//go:def.bzl", "GoArchive")

# buildifier: disable=bzl-visibility
load("@rules_go//go/private:providers.bzl", "GoStdLib")
load("@rules_go//go/tools/gopackagesdriver:aspect.bzl", "GoPkgInfo", "go_pkg_info_aspect")
load(":golangci_lint.bzl", "GO_TOOLCHAIN", "driver_config", "driver_inputs")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

_DeadcodeRootsInfo = provider(
    doc = "Main-repository Go packages a target reaches.",
    fields = {
        "importpaths": "depset of import paths",
        "roots": "depset of package IDs (labels)",
    },
)

def _roots_aspect_impl(target, ctx):
    roots = []
    importpaths = []
    if target.label.repo_name == "" and GoArchive in target:
        data = target[GoArchive].data
        roots.append(str(data.label))
        importpaths.append(data.importpath)
    transitive = [
        dep[_DeadcodeRootsInfo]
        for attr in ("deps", "embed")
        for dep in getattr(ctx.rule.attr, attr, []) or []
        if _DeadcodeRootsInfo in dep
    ]
    return [_DeadcodeRootsInfo(
        roots = depset(roots, transitive = [t.roots for t in transitive]),
        importpaths = depset(importpaths, transitive = [t.importpaths for t in transitive]),
    )]

_roots_aspect = aspect(
    implementation = _roots_aspect_impl,
    attr_aspects = ["deps", "embed"],
)

def _regexp_quote(s):
    out = ""
    for c in s.elems():
        out += "\\" + c if c in ".+*?()|[]{}^$\\" else c
    return out

def _merge_pkg_info(infos):
    stdlib_json = [i.stdlib_json_file for i in infos if i.stdlib_json_file]
    return struct(
        stdlib_json_file = stdlib_json[0] if stdlib_json else None,
        stdlib_cache_dir = depset(transitive = [i.stdlib_cache_dir for i in infos if i.stdlib_cache_dir]),
        pkg_json_files = depset(transitive = [i.pkg_json_files for i in infos]),
        compiled_go_files = depset(transitive = [i.compiled_go_files for i in infos]),
        export_files = depset(transitive = [i.export_files for i in infos]),
    )

def _go_deadcode_test_impl(ctx):
    targets = ctx.attr.srcs + ([ctx.attr._bzltestutil] if ctx.attr.test else [])
    pkg_info = _merge_pkg_info([t[GoPkgInfo] for t in targets if GoPkgInfo in t])
    roots = depset(transitive = [t[_DeadcodeRootsInfo].roots for t in ctx.attr.srcs]).to_list()
    if not roots:
        fail("srcs reach no Go package of the main repository")

    filter = ctx.attr.filter
    if not filter:
        importpaths = depset(transitive = [t[_DeadcodeRootsInfo].importpaths for t in ctx.attr.srcs]).to_list()
        filter = "^(" + "|".join([_regexp_quote(p) for p in sorted(importpaths)]) + ")$"

    stdlib = ctx.attr._go_stdlib[GoStdLib]
    config = ctx.actions.declare_file(ctx.label.name + ".driver")
    driver_config(ctx, config, pkg_info, roots, stdlib, test_main = ctx.attr.test)

    report = ctx.actions.declare_file(ctx.label.name + ".deadcode.txt")
    args = ctx.actions.args()
    args.add(ctx.executable._deadcode)
    args.add(ctx.executable._driver)
    args.add(config)
    args.add(ctx.toolchains[GO_TOOLCHAIN].sdk.go)
    args.add(report)
    if ctx.attr.test:
        args.add("-test")
    args.add("-filter=" + filter)
    args.add_all(ctx.attr.deadcode_args)
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset([config], transitive = [driver_inputs(ctx, pkg_info, stdlib)]),
        outputs = [report],
        tools = [ctx.executable._deadcode, ctx.executable._driver],
        mnemonic = "GoDeadcode",
        progress_message = "Finding dead code for %{label}",
        toolchain = GO_TOOLCHAIN,
    )

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._test_runner,
        output = script,
        substitutions = {"@@REPORT@@": report.short_path},
        is_executable = True,
    )
    return [DefaultInfo(executable = script, runfiles = ctx.runfiles(files = [report]))]

go_deadcode_test = rule(
    implementation = _go_deadcode_test_impl,
    test = True,
    doc = """Fails when deadcode reports a function that nothing reaches.

The program is every main-repository Go package `srcs` reach through `deps`
and `embed`, as `deadcode ./...` would load the module's packages. Its
entry points are the `main` packages among them and, with `test`, the test
main of every go_test among them, so a function only tests call is live.
List the binaries and tests.

deadcode reports only functions in the packages `filter` matches; by
default, exactly the main-repository packages of the program.""",
    attrs = {
        "deadcode_args": attr.string_list(doc = "Extra deadcode flags, such as `-generated`."),
        "filter": attr.string(doc = "deadcode's `-filter`: a regular expression of the import paths to report on."),
        "srcs": attr.label_list(
            aspects = [go_pkg_info_aspect, _roots_aspect],
            mandatory = True,
            doc = "Go binaries and tests (and libraries) making up the program.",
        ),
        "test": attr.bool(default = True, doc = "Analyze tests too (deadcode's `-test`)."),
        "_bzltestutil": attr.label(
            default = Label("@rules_go//go/tools/bzltestutil"),
            aspects = [go_pkg_info_aspect],
        ),
        "_deadcode": attr.label(
            default = Label("@org_golang_x_tools//cmd/deadcode"),
            executable = True,
            cfg = "exec",
        ),
        "_driver": attr.label(
            default = Label("//private/driver"),
            executable = True,
            cfg = "exec",
        ),
        "_go_pure": attr.label(default = Label("@rules_go//go/config:pure")),
        "_go_stdlib": attr.label(default = Label("@rules_go//:stdlib")),
        "_go_tags": attr.label(default = Label("@rules_go//go/config:tags")),
        "_runner": attr.label(
            default = Label("//private:deadcode.sh"),
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "_test_runner": attr.label(
            default = Label("//private:report_test.sh.tpl"),
            allow_single_file = True,
        ),
    },
    toolchains = [GO_TOOLCHAIN],
)
