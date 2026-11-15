# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Build, lint, update and compare Structurizr workspace exports."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@tbhb_rules//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

visibility(["//"])

_ExportsInfo = provider(doc = "Rendered workspace exports.", fields = {"tree": "The exported workspace and diagrams directory."})

def _java(ctx):
    # Run the actual launcher beside its runtime libraries, rather than the
    # hub symlink. Keep the entire runtime in action inputs and runfiles.
    files = ctx.attr._jre[DefaultInfo].default_runfiles.files.to_list()
    for file in files:
        if file.basename == "java" and file.dirname.endswith("/bin"):
            return file, files
    fail("the JRE hub must include bin/java and its runtime tree")

def _cli(ctx):
    for file in ctx.files._cli:
        if file.basename == "structurizr-cli.jar":
            return file
    fail("the Structurizr hub must include lib/structurizr-cli.jar")

def _sources(ctx, short = False):
    args = []
    for file in [ctx.file.dsl] + ctx.files.data:
        relative = _package_file(ctx, file)
        args += [file.short_path if short else file.path, relative]
    return args

def _renders_impl(ctx):
    java, runtime = _java(ctx)
    tree = ctx.actions.declare_directory(ctx.label.name + "/exports")
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = ["render", java.path, _cli(ctx).dirname, _package_file(ctx, ctx.file.dsl), ctx.file._plantuml.path, tree.path, ctx.files._fonts[0].dirname] + _sources(ctx),
        inputs = depset([ctx.file.dsl, ctx.file._plantuml] + ctx.files.data + ctx.files._cli + ctx.files._fonts + runtime),
        outputs = [tree],
        mnemonic = "StructurizrExport",
        progress_message = "Exporting Structurizr workspace %{input}",
    )
    return [DefaultInfo(files = depset([tree])), _ExportsInfo(tree = tree)]

_TOOL_ATTRS = {
    "_cli": attr.label(default = Label("@tbhb_rules_structurizr_cli//:structurizr"), cfg = "exec"),
    "_fonts": attr.label(default = Label("@tbhb_rules_liberation_fonts//:fonts"), cfg = "exec"),
    "_jre": attr.label(default = Label("@tbhb_rules_jre//:java"), executable = True, cfg = "exec"),
    "_plantuml": attr.label(default = Label("@tbhb_rules_plantuml//:plantuml"), allow_single_file = True, cfg = "exec"),
    "_runner": attr.label(default = Label("//private:runner"), executable = True, cfg = "exec"),
}

_renders = rule(
    implementation = _renders_impl,
    attrs = _TOOL_ATTRS | {
        "data": attr.label_list(allow_files = True),
        "dsl": attr.label(allow_single_file = [".dsl"], mandatory = True),
    },
)

def _script(ctx, arguments, files, extra_runfiles = []):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "#!/usr/bin/env bash\nset -euo pipefail\nexec " + " ".join([shell.quote(word) for word in [ctx.executable._runner.short_path] + arguments]) + "\n",
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = files).merge(ctx.attr._runner[DefaultInfo].default_runfiles)
    for extra in extra_runfiles:
        runfiles = runfiles.merge(extra)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

def _lint_impl(ctx):
    java, runtime = _java(ctx)
    return _script(
        ctx,
        ["lint", java.short_path, _cli(ctx).short_path.rpartition("/")[0], _package_file(ctx, ctx.file.dsl)] + _sources(ctx, short = True),
        [ctx.file.dsl] + ctx.files.data + ctx.files._cli + runtime,
    )

_lint_test = rule(
    implementation = _lint_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | _TOOL_ATTRS | {
        "data": attr.label_list(allow_files = True),
        "dsl": attr.label(allow_single_file = [".dsl"], mandatory = True),
    },
)

def _package_file(ctx, file):
    if not file.is_source or file.owner.repo_name != ctx.label.repo_name or file.owner.package != ctx.label.package:
        fail("workspace inputs and committed exports must be source files in the target's package")
    return file.owner.name

def _manifest(ctx):
    lines = []
    for file in ctx.files.committed:
        path = _package_file(ctx, file)
        if path == ctx.attr.workspace_json:
            relative = "workspace.json"
        else:
            relative = "diagrams/" + path[len(ctx.attr.diagrams_dir) + 1:]
        lines.append(relative + "\t" + file.short_path)
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "\n".join(sorted(lines)) + "\n" if lines else "")
    return manifest

def _exports_impl(ctx):
    tree = ctx.attr.renders[_ExportsInfo].tree
    manifest = _manifest(ctx)
    args = [ctx.attr.mode, tree.short_path, manifest.short_path]
    if ctx.attr.mode == "update":
        prefix = ctx.label.package + "/" if ctx.label.package else ""
        args += [prefix + ctx.attr.workspace_json, prefix + ctx.attr.diagrams_dir]
    return _script(ctx, args, [tree, manifest] + ctx.files.committed)

_EXPORT_ATTRS = {
    "committed": attr.label_list(allow_files = True),
    "diagrams_dir": attr.string(mandatory = True),
    "mode": attr.string(mandatory = True, values = ["check", "png", "update"]),
    "renders": attr.label(mandatory = True, providers = [_ExportsInfo]),
    "workspace_json": attr.string(mandatory = True),
    "_runner": attr.label(default = Label("//private:runner"), executable = True, cfg = "exec"),
}

_exports_test = rule(
    implementation = _exports_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | _EXPORT_ATTRS,
)

_update = rule(
    implementation = _exports_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | _EXPORT_ATTRS,
)

def structurizr_workspace(name, dsl, workspace_json, diagrams_dir, data = [], **kwargs):
    """Exports a workspace and checks its committed JSON, SVG and PNG files.

    Creates `<name>` (update with `bazel run`), `<name>.renders` (a tree
    containing workspace.json, PlantUML text, SVGs and PNGs), and
    `<name>_test` (a suite of lint, freshness and PNG tests).

    Lint runs both `validate -w` and `inspect -w -s error,warning`, even
    after validation fails. ERROR and WARNING inspections fail; INFO and
    IGNORE do not. Any command error fails. Violation lines in the inspect
    output also fail when the count wraps the process exit status to zero.

    JSON and SVG comparisons use bytes on every supported platform (Linux and
    macOS on x64 and arm64). Linux x86_64 CI proved SVG and JSON byte-identical
    to committed files generated on macOS arm64. PNG byte comparisons run only
    on macOS arm64. Missing SVGs or PNGs and orphan files fail on all supported
    platforms. JVM settings use UTC and en_US.UTF-8. The CI plan selects Linux
    x86_64, Linux arm64 and macOS arm64, excluding Windows (no JRE pin).
    The only CI run read so far ran Structurizr on Linux x86_64, before the
    plan added Linux arm64 and macOS arm64. No Linux arm64 or macOS CI result
    is recorded here, and Windows is unsupported.

    The exporter produces a main diagram and a legend (`-key`) for each
    view. Both are rendered with `!pragma layout smetana`, headless, using
    the pinned JRE, MIT PlantUML and SIL-OFL-1.1 Liberation Sans 2.1.5.
    Graphviz is unnecessary. Fontconfig sees only pinned fonts; the renderer
    also checks that the JVM opened the pinned TTF and that SVGs specify
    Liberation Sans, which no test covers yet.
    Linux requires host libfontconfig and libfreetype. Java HTTP(S) requests
    use an unreachable proxy; PlantUML uses its sandbox profile. DSL is trusted
    input: scripts, plugins and absolute includes can access the host.

    Paths are relative to this package. Keep committed renders byte for
    byte in Git and exclude them from whitespace and line-ending fixers.
    Imported DSL, documentation and decisions must be local source files
    in this package and listed in `data`. Inputs are copied before export
    so documentation filenames remain relative even in symlinked sandboxes.
    The update target copies JSON and images and removes orphan images;
    PlantUML text remains in the output tree.

    Args:
        name: Update target name; tests are grouped as `<name>_test`.
        dsl: Local workspace DSL source with basename workspace.dsl.
        workspace_json: Committed JSON path, including its filename.
        diagrams_dir: Directory of committed SVG and PNG files.
        data: Local inputs read by the workspace, relative to the DSL.
        **kwargs: Common target attributes, including tags and visibility.
    """
    if str(dsl).split(":")[-1].split("/")[-1] != "workspace.dsl":
        fail("dsl basename must be workspace.dsl")
    if diagrams_dir.startswith("/"):
        fail("export paths must be package-relative paths without parent traversal")
    diagrams_dir = "/".join([part for part in diagrams_dir.split("/") if part and part != "."])
    for path in [workspace_json, diagrams_dir]:
        if path.startswith("/") or ".." in path.split("/") or "\t" in path or "\n" in path:
            fail("export paths must be package-relative paths without parent traversal")
    if not diagrams_dir:
        fail("diagrams_dir must name a directory")
    committed = native.glob([workspace_json, diagrams_dir + "/*.svg", diagrams_dir + "/*.png"], allow_empty = True)
    _renders(name = name + ".renders", dsl = dsl, data = data, **kwargs)
    _lint_test(name = name + "_lint_test", dsl = dsl, data = data, **kwargs)
    common = dict(committed = committed, diagrams_dir = diagrams_dir, workspace_json = workspace_json, renders = ":" + name + ".renders")
    _update(name = name, mode = "update", **(common | kwargs))
    _exports_test(name = name + "_freshness_test", mode = "check", **(common | kwargs))
    _exports_test(
        name = name + "_png_test",
        mode = "png",
        **(common | kwargs | {"target_compatible_with": kwargs.get("target_compatible_with", []) + ["@platforms//os:macos", "@platforms//cpu:arm64"]})
    )
    native.test_suite(
        name = name + "_test",
        tests = [":" + name + suffix for suffix in ["_lint_test", "_freshness_test", "_png_test"]],
        tags = [tag for tag in kwargs.get("tags", []) if tag == "manual"],
        **{key: value for key, value in kwargs.items() if key in ["visibility", "testonly"]}
    )
