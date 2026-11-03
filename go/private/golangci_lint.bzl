# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""golangci-lint as a per-package Bazel aspect, and a test over its reports.

Each go_library, go_binary and go_test of the main repository gets its own
action that runs the real golangci-lint binary with the consumer's config.
The action loads the package through a static GOPACKAGESDRIVER
(`//private/driver`) that answers from the metadata rules_go's
`go_pkg_info_aspect` computed: sources and export data of the package and
of every dependency, the standard library included. No go command builds
anything, and no module cache, network or Bazel server is used, so each
report is an ordinary cacheable action output.

See docs/golangci-lint.md for what this cannot see.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_go//go:def.bzl", "GoArchive")

# GoStdLib, the precompiled standard library, is not exported by go:def.bzl.
# buildifier: disable=bzl-visibility
load("@rules_go//go/private:providers.bzl", "GoStdLib")
load("@rules_go//go/tools/gopackagesdriver:aspect.bzl", "GoPkgInfo", "go_pkg_info_aspect")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

GolangciLintInfo = provider(
    doc = "golangci-lint reports of a target and the main-repository targets it depends on.",
    fields = {
        "reports": """depset of files: per linted target a report `<name>.golangci-lint-<key>.txt`
(one finding per line, empty when clean) and next to it `<name>.golangci-lint-<key>.covers`
(`variant=lib` or `variant=test`, then the linted source files). `<key>` tells the
aspects made by different factory calls apart.""",
    },
)

GO_TOOLCHAIN = "@rules_go//go:toolchain"

DEFAULT_RULE_KINDS = ["go_binary", "go_library", "go_test"]

def _path(f):
    return f.path

def _pkg_json_line(f):
    return "pkg_json=" + f.path

def driver_config(ctx, out, pkg_info, roots, stdlib):
    """Writes the static driver's config file.

    Args:
        ctx: The aspect or rule context; needs the `_go_tags` and `_go_pure`
            attributes and the Go toolchain.
        out: The file to write.
        pkg_info: GoPkgInfo of the roots, which covers their dependencies.
        roots: Package IDs (labels) to answer with.
        stdlib: The GoStdLib provider.
    """
    toolchain = ctx.toolchains[GO_TOOLCHAIN]
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add("goos=" + toolchain.default_goos)
    args.add("goarch=" + toolchain.default_goarch)
    args.add("go_version=" + toolchain.sdk.version)
    args.add("cgo_enabled=" + ("0" if ctx.attr._go_pure[BuildSettingInfo].value else "1"))
    args.add_all(ctx.attr._go_tags[BuildSettingInfo].value, format_each = "tag=%s")
    args.add_all(stdlib.libs, map_each = _path, format_each = "stdlib_pkg_dir=%s", expand_directories = False)
    args.add_all(roots, format_each = "root=%s")
    if pkg_info.stdlib_json_file:
        args.add("pkg_json=" + pkg_info.stdlib_json_file.path)
    args.add_all(pkg_info.pkg_json_files, map_each = _pkg_json_line)
    ctx.actions.write(out, args)

def driver_inputs(ctx, pkg_info, stdlib):
    """The files the driver and the tool read, besides the config.

    Every package's sources are inputs, the standard library's too:
    golangci-lint computes analysis facts for dependencies from source when
    its cache holds none, which in a fresh action is always.

    Args:
        ctx: The aspect or rule context.
        pkg_info: GoPkgInfo of the roots.
        stdlib: The GoStdLib provider.

    Returns:
        A depset of files.
    """
    sdk = ctx.toolchains[GO_TOOLCHAIN].sdk
    return depset(
        [sdk.go, sdk.root_file] + ([pkg_info.stdlib_json_file] if pkg_info.stdlib_json_file else []),
        transitive = [
            pkg_info.pkg_json_files,
            pkg_info.compiled_go_files,
            pkg_info.export_files,
            pkg_info.stdlib_cache_dir,
            stdlib.libs,
            sdk.srcs,
            sdk.headers,
        ],
    )

def _own_go_files(ctx):
    return [f for f in ctx.rule.files.srcs if f.extension == "go"] if hasattr(ctx.rule.files, "srcs") else []

def _covered_go_files(target, ctx):
    """The workspace sources the lint action reports on.

    A go_test compiles the sources of the libraries it embeds with its own,
    as one package; golangci-lint lints that test variant in place of the
    library, so its report covers the library's files too.
    """
    files = _own_go_files(ctx)
    if ctx.rule.kind == "go_test":
        archive = target[GoArchive]
        for dep in archive.direct:
            if dep.data.label == archive.data.label:
                files = [f for f in dep.source.srcs if f.extension == "go"]
                break
    return [f for f in files if f.is_source]

def _lint(target, ctx):
    pkg_info = target[GoPkgInfo]
    stdlib = ctx.attr._go_stdlib[GoStdLib]
    name = "{}.golangci-lint-{}".format(target.label.name, ctx.attr._key)

    config = ctx.actions.declare_file(name + ".driver")
    driver_config(ctx, config, pkg_info, [str(target[GoArchive].data.label)], stdlib)

    # Which files the report speaks for. golangci_lint_test merges reports
    # by it: findings in a file a test variant covers come from test
    # variants only, as golangci-lint itself lints a package with tests only
    # as its test variant.
    covered = _covered_go_files(target, ctx)
    covers = ctx.actions.declare_file(name + ".covers")
    ctx.actions.write(covers, "".join(
        ["variant={}\n".format("test" if ctx.rule.kind == "go_test" else "lib")] +
        [f.short_path + "\n" for f in covered],
    ))

    go_mod = ctx.file._go_mod if hasattr(ctx.attr, "_go_mod") else None
    mirror = ctx.actions.declare_file(name + ".mirror")
    ctx.actions.write(mirror, "".join([
        f.path + "\n"
        for f in covered + [ctx.file._config] + ([go_mod] if go_mod else []) + ctx.files._data
    ]))

    report = ctx.actions.declare_file(name + ".txt")
    args = ctx.actions.args()
    args.add(ctx.executable._golangci_lint)
    args.add(ctx.executable._report)
    args.add(ctx.executable._driver)
    args.add(config)
    args.add(ctx.toolchains[GO_TOOLCHAIN].sdk.go)
    args.add(ctx.file._config)
    args.add(go_mod.path if go_mod else "")
    args.add(mirror)
    args.add(report)
    args.add_all(ctx.attr._args)

    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = [args],
        inputs = depset(
            [config, mirror, ctx.file._config] + ([go_mod] if go_mod else []) + ctx.files._data,
            transitive = [driver_inputs(ctx, pkg_info, stdlib)],
        ),
        outputs = [report],
        tools = [ctx.executable._golangci_lint, ctx.executable._report, ctx.executable._driver],
        mnemonic = "GolangciLint",
        progress_message = "Linting %{label} with golangci-lint",
        toolchain = GO_TOOLCHAIN,
    )
    return [report, covers]

def _golangci_lint_aspect_impl(target, ctx):
    transitive = []
    for attr in ("deps", "embed"):
        for dep in getattr(ctx.rule.attr, attr, []) or []:
            if GolangciLintInfo in dep:
                transitive.append(dep[GolangciLintInfo].reports)

    direct = []
    if (ctx.rule.kind in ctx.attr._rule_kinds and
        target.label.repo_name == "" and
        GoPkgInfo in target and
        GoArchive in target and
        _own_go_files(ctx)):
        direct = _lint(target, ctx)

    reports = depset(direct, transitive = transitive)
    return [
        GolangciLintInfo(reports = reports),
        OutputGroupInfo(golangci_lint = reports),
    ]

def golangci_lint_aspect_factory(
        config,
        go_mod = None,
        tool = Label("@multitool//tools/golangci-lint"),
        data = [],
        args = [],
        rule_kinds = DEFAULT_RULE_KINDS):
    """Makes a golangci-lint aspect.

    Assign the result to a global in a .bzl file:

    ```starlark
    golangci_lint = golangci_lint_aspect_factory(config = Label("//:.golangci.yml"))
    ```

    The aspect lints each matching target of the main repository, and
    follows `deps` and `embed` to lint the main-repository targets those
    reach. Build `--aspects=//tools/lint:linters.bzl%golangci_lint
    --output_groups=golangci_lint` for the reports, or wrap targets in a
    test made by `golangci_lint_test_factory`.

    Args:
        config: Label of the golangci-lint config. Pass a `Label`, so it
            resolves in the calling repository.
        go_mod: Label of the module's go.mod. golangci-lint then runs from
            its directory, as it would outside Bazel, and takes the Go
            version from it; without it, the version is the SDK's.
        tool: The golangci-lint binary.
        data: Files the config refers to (a depguard list, a custom
            dictionary).
        args: Extra `golangci-lint run` flags.
        rule_kinds: Rule kinds to lint.

    Returns:
        An aspect.
    """
    attrs = {
        "_args": attr.string_list(default = args),
        "_config": attr.label(default = config, allow_single_file = True),
        "_data": attr.label_list(default = data, allow_files = True),
        "_driver": attr.label(
            default = Label("//private/driver"),
            executable = True,
            cfg = "exec",
        ),
        "_go_pure": attr.label(default = Label("@rules_go//go/config:pure")),
        "_go_stdlib": attr.label(default = Label("@rules_go//:stdlib")),
        "_go_tags": attr.label(default = Label("@rules_go//go/config:tags")),
        "_golangci_lint": attr.label(default = tool, executable = True, cfg = "exec"),
        "_report": attr.label(
            default = Label("//private/report"),
            executable = True,
            cfg = "exec",
        ),
        "_rule_kinds": attr.string_list(default = rule_kinds),
        "_runner": attr.label(
            default = Label("//private:golangci_lint.sh"),
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    }

    # An aspect's private attribute needs a default, so a missing go.mod is
    # a missing attribute.
    if go_mod:
        attrs["_go_mod"] = attr.label(default = go_mod, allow_single_file = True)
    return aspect(
        implementation = _golangci_lint_aspect_impl,
        attr_aspects = ["deps", "embed"],
        requires = [go_pkg_info_aspect],
        toolchains = [GO_TOOLCHAIN],
        provides = [GolangciLintInfo],
        attrs = attrs,
    )

def _report_short_path(f):
    return f.short_path if f.extension == "txt" else None

def write_report_manifest(ctx, reports):
    """Writes the list of report files in `reports`, by short path.

    Args:
        ctx: The rule context.
        reports: A depset from GolangciLintInfo.reports.

    Returns:
        The manifest file.
    """
    manifest = ctx.actions.declare_file(ctx.label.name + ".reports")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add_all(reports, map_each = _report_short_path)
    ctx.actions.write(manifest, args)
    return manifest

def _golangci_lint_test_impl(ctx):
    reports = depset(transitive = [t[GolangciLintInfo].reports for t in ctx.attr.srcs])
    manifest = write_report_manifest(ctx, reports)

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@MANIFEST@@": manifest.short_path,
            "@@MERGE@@": ctx.executable._merge.short_path,
        },
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [manifest, ctx.executable._merge], transitive_files = reports),
    )]

def golangci_lint_test_factory(aspect):
    """Makes a test rule that fails when golangci-lint reports any issue.

    ```starlark
    golangci_lint_test = golangci_lint_test_factory(golangci_lint)
    ```

    The test takes `srcs`, the Go targets to lint (and through `deps` and
    `embed`, the main-repository targets they reach). It fails when any
    report holds a finding, printing them all, and when no package was
    linted at all. Findings in a library's files come from a go_test that
    embeds it when `srcs` reach one, as golangci-lint lints a package with
    tests only as its test variant.

    Args:
        aspect: An aspect from `golangci_lint_aspect_factory`.

    Returns:
        A test rule.
    """
    return rule(
        implementation = _golangci_lint_test_impl,
        test = True,
        doc = "Fails when golangci-lint reports an issue in `srcs` or the main-repository targets they depend on.",
        attrs = {
            "srcs": attr.label_list(
                aspects = [aspect],
                mandatory = True,
                doc = "Go targets to lint.",
            ),
            "_merge": attr.label(
                default = Label("//private:golangci_lint_merge.sh"),
                allow_single_file = True,
                executable = True,
                cfg = "target",
            ),
            "_runner": attr.label(
                default = Label("//private:golangci_lint_test.sh.tpl"),
                allow_single_file = True,
            ),
        },
    )
