# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`d2_diagrams`: D2 diagrams rendered to SVG and PNG, committed beside their sources.

Each source `x.d2` has three committed files beside it: `x.d2.svg`, D2's
own SVG; `x.d2.png`, the SVG rasterized by resvg at twice its size and
optimized by oxipng; and `x.d2.sha256`, the `shasum -a 256` lines of
`x.d2`, `x.d2.svg` and `x.d2.png`, in that order.

The check renders the SVG again and compares its SHA-256 with the
committed one's, and recomputes the manifest from the committed files. It
does not render the PNG again, because rasterized pixels can differ across
platforms; the manifest vouches for it instead.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@tbhb_rules//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //:defs.bzl.
visibility(["//"])

_SUFFIXES = [".svg", ".png", ".sha256"]

_D2RendersInfo = provider(
    doc = "The renders of each D2 source.",
    fields = {
        "diagrams": "A list of structs: `path` (the source's path in the package), `src`, `svg`, `png` and `sha256` (Files).",
    },
)

def _package_path(ctx, file):
    """A source file's path relative to the package of `ctx`'s target."""
    owner = file.owner
    if not file.is_source or owner.repo_name != ctx.label.repo_name or owner.package != ctx.label.package:
        fail("{}: {} is not a source file of this package; renders go beside their sources".format(ctx.label, file.short_path))
    return owner.name

def _display(ctx, path):
    """A package path as a workspace-relative path."""
    return ctx.label.package + "/" + path if ctx.label.package else path

def _binary(target):
    """The file an action runs for a pinned tool.

    On Windows the hub's executable is a Bash shim that finds the binary
    through a runfiles tree an action does not have: run the binary itself.
    """
    for f in target[DefaultInfo].default_runfiles.files.to_list():
        if f.extension == "exe":
            return f
    return target[DefaultInfo].files_to_run.executable

def _manifest(ctx, src, svg, png, out):
    ctx.actions.run(
        executable = ctx.executable._runner,
        arguments = ["manifest", src.path, svg.path, png.path, out.path],
        inputs = [src, svg, png],
        outputs = [out],
        mnemonic = "D2Manifest",
        progress_message = "Hashing the renders of %{input}",
    )

def _call(*words):
    return " ".join([shell.quote(w) for w in words])

def _orphans(ctx, diagrams):
    """The committed renders whose source is not among the diagrams."""
    sources = {d.path: None for d in diagrams}
    orphans = []
    for f in ctx.files.committed:
        path = _package_path(ctx, f)
        for suffix in _SUFFIXES:
            if path.endswith(suffix) and path[:-len(suffix)] not in sources:
                orphans.append((path, path[:-len(suffix)]))
    return sorted(orphans)

def _d2_renders_impl(ctx):
    d2 = _binary(ctx.attr._d2)
    resvg = _binary(ctx.attr._resvg)
    oxipng = _binary(ctx.attr._oxipng)
    fonts = ctx.files._fonts
    diagrams = []
    for src in ctx.files.srcs:
        path = _package_path(ctx, src)
        out = ctx.label.name + "/" + path
        svg = ctx.actions.declare_file(out + ".svg")
        png = ctx.actions.declare_file(out + ".png")
        sha256 = ctx.actions.declare_file(out + ".sha256")
        ctx.actions.run(
            executable = ctx.executable._runner,
            arguments = ["svg", d2.path, src.path, svg.path],
            inputs = [src],
            outputs = [svg],
            tools = [d2],
            mnemonic = "D2Svg",
            progress_message = "Rendering %{input} to SVG",
        )
        ctx.actions.run(
            executable = ctx.executable._runner,
            arguments = ["png", resvg.path, oxipng.path, fonts[0].dirname, svg.path, png.path],
            inputs = [svg] + fonts,
            outputs = [png],
            tools = [resvg, oxipng],
            mnemonic = "D2Png",
            progress_message = "Rendering %{input} to PNG",
        )
        _manifest(ctx, src, svg, png, sha256)
        diagrams.append(struct(path = path, src = src, svg = svg, png = png, sha256 = sha256))
    return [
        DefaultInfo(files = depset([f for d in diagrams for f in (d.svg, d.png, d.sha256)])),
        _D2RendersInfo(diagrams = diagrams),
    ]

_d2_renders = rule(
    implementation = _d2_renders_impl,
    doc = "Renders each D2 source to its SVG, PNG and manifest, in the output tree.",
    attrs = {
        "srcs": attr.label_list(allow_files = [".d2"], doc = "D2 sources of this package."),
        "_d2": attr.label(default = Label("@tbhb_rules_d2_cli//:d2"), executable = True, cfg = "exec"),
        "_fonts": attr.label(default = Label("@tbhb_rules_source_sans_pro//:ttf"), cfg = "exec"),
        "_oxipng": attr.label(default = Label("@tbhb_rules_oxipng//:oxipng"), executable = True, cfg = "exec"),
        "_resvg": attr.label(default = Label("@tbhb_rules_resvg//:resvg"), executable = True, cfg = "exec"),
        "_runner": attr.label(default = Label("//private:render_runner"), executable = True, cfg = "exec"),
    },
)

def _d2_write_impl(ctx):
    diagrams = ctx.attr.renders[_D2RendersInfo].diagrams
    calls = []
    for d in diagrams:
        for suffix, f in zip(_SUFFIXES, (d.svg, d.png, d.sha256)):
            calls.append(_call("put", f.short_path, _display(ctx, d.path + suffix)))
    for path, _ in _orphans(ctx, diagrams):
        calls.append(_call("remove", _display(ctx, path)))
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        substitutions = {"@@CALLS@@": "\n".join(calls)},
        is_executable = True,
    )
    files = [f for d in diagrams for f in (d.svg, d.png, d.sha256)]
    executable, runfiles = shell_executable(ctx, script, ctx.runfiles(files = files))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_d2_write = rule(
    implementation = _d2_write_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = "Copies the renders beside their sources and removes orphaned renders, for `bazel run`.",
    attrs = SHELL_ATTRS | {
        "committed": attr.label_list(allow_files = True, doc = "The renders in the package."),
        "renders": attr.label(mandatory = True, providers = [_D2RendersInfo]),
        "_template": attr.label(default = Label("//private:write.sh.tpl"), allow_single_file = True),
    },
)

def _d2_diagrams_test_impl(ctx):
    diagrams = ctx.attr.renders[_D2RendersInfo].diagrams
    committed = {_package_path(ctx, f): f for f in ctx.files.committed}
    calls = []
    files = []
    for d in diagrams:
        svg, png, sha256 = [committed.get(d.path + suffix) for suffix in _SUFFIXES]
        for suffix, f in zip(_SUFFIXES, (svg, png, sha256)):
            if not f:
                calls.append(_call("missing", _display(ctx, d.path + suffix)))
        if svg:
            calls.append(_call("svg", d.svg.short_path, svg.short_path, _display(ctx, d.path), _display(ctx, d.path + ".svg")))
            files += [d.svg, svg]
        if svg and png and sha256:
            computed = ctx.actions.declare_file(ctx.label.name + "/" + d.path + ".sha256")
            _manifest(ctx, d.src, svg, png, computed)
            calls.append(_call("manifest", computed.short_path, sha256.short_path, _display(ctx, d.path + ".sha256")))
            files += [computed, sha256]
    for path, source in _orphans(ctx, diagrams):
        calls.append(_call("orphan", _display(ctx, path), _display(ctx, source)))
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        substitutions = {
            "@@CALLS@@": "\n".join(calls),
            "@@COUNT@@": str(len(diagrams)),
            "@@PACKAGE@@": "//" + ctx.label.package,
            "@@RUN@@": "bazel run //{}:{}".format(ctx.label.package, ctx.attr.run_target),
        },
        is_executable = True,
    )
    executable, runfiles = shell_executable(ctx, script, ctx.runfiles(files = files))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_d2_diagrams_test = rule(
    implementation = _d2_diagrams_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = "Fails when a committed render is stale, missing or orphaned.",
    attrs = SHELL_ATTRS | {
        "committed": attr.label_list(allow_files = True, doc = "The renders in the package."),
        "renders": attr.label(mandatory = True, providers = [_D2RendersInfo]),
        "run_target": attr.string(mandatory = True, doc = "The name of the target that writes the renders."),
        "_runner": attr.label(default = Label("//private:render_runner"), executable = True, cfg = "exec"),
        "_template": attr.label(default = Label("//private:check.sh.tpl"), allow_single_file = True),
    },
)

def d2_diagrams(name, srcs = None, **kwargs):
    """Renders D2 diagrams, writes the renders beside their sources, and checks them.

    For each source `x.d2`, the renders are `x.d2.svg` (D2's own SVG,
    ending in one newline), `x.d2.png` (the SVG rasterized by resvg at
    twice its size, with D2's embedded fonts swapped for Source Sans Pro,
    then optimized by oxipng) and `x.d2.sha256` (the `shasum -a 256` lines
    of `x.d2`, `x.d2.svg` and `x.d2.png`).

    Creates:

    - `<name>.renders`: the renders, in the output tree.
    - `<name>`, for `bazel run`: copies the renders beside their sources
      and removes renders whose source is gone.
    - `<name>_test`: fails when a source has a missing render, when the
      committed SVG differs from a fresh render, when the committed
      manifest does not hold the hashes of the committed files, or when a
      render (`*.d2.svg`, `*.d2.png` or `*.d2.sha256` anywhere in the
      package) has no source among `srcs`. The PNG is not rendered again,
      since rasterized pixels can differ across platforms: the manifest
      vouches for it.

    The renders must reach Git unchanged: mark them `-text` or `eol=lf` in
    `.gitattributes`, and the PNG `binary`.

    Args:
        name: Name of the `bazel run` target; the test is `<name>_test`.
        srcs: D2 sources of this package; by default every `*.d2` file in
            its directory. Sources in subdirectories get their renders
            beside them.
        **kwargs: Common attributes, such as `tags` and `visibility`, for
            every target.
    """
    if srcs == None:
        srcs = native.glob(["*.d2"], allow_empty = True)
    committed = native.glob(["**/*.d2" + suffix for suffix in _SUFFIXES], allow_empty = True)
    renders = ":{}.renders".format(name)
    _d2_renders(name = name + ".renders", srcs = srcs, **kwargs)
    _d2_write(name = name, renders = renders, committed = committed, **kwargs)
    _d2_diagrams_test(name = name + "_test", renders = renders, committed = committed, run_target = name, **kwargs)
