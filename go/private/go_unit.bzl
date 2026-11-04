# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""What the rules that run a Go tool over one package of a module share.

A unit is the package a rule's `tests` are in. Its action copies the unit's
sources and tests, the main-repository sources of the packages they depend
on, `data`, and go.mod and go.sum into a scratch module (the `scratch` Go
package, which reads the manifest written here), and runs the tool with the
toolchain's go, offline.

A rule that runs over the whole module, at test time, takes `srcs` instead
(MODULE_ATTRS and `go_module`): the same scratch module and manifest, with
paths relative to the runfiles directory.
"""

load(":go_srcs.bzl", "GoSrcsInfo", "go_srcs_aspect")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

GO_TOOLCHAIN = "@rules_go//go:toolchain"

# The attributes of a rule over a module: its go.mod, go.sum and proxy, and
# the files its tests read.
MODULE_ATTRS = {
    "data": attr.label_list(
        allow_files = True,
        doc = "Other files the tests read (testdata, embedded files), in the module directory.",
    ),
    "go_mod": attr.label(mandatory = True, allow_single_file = ["go.mod"]),
    "go_sum": attr.label(allow_single_file = ["go.sum"], doc = "The module's go.sum, when it has requirements."),
    "proxy": attr.label(
        allow_files = True,
        doc = "The `:proxy` target of a go_mod_proxy repository made from go.sum, when the module has requirements.",
    ),
}

# The attributes a unit's rule takes.
UNIT_ATTRS = MODULE_ATTRS | {
    "tests": attr.label_list(
        aspects = [go_srcs_aspect],
        mandatory = True,
        doc = "go_test targets of one package.",
    ),
}

def _dirname(path):
    return path.rpartition("/")[0]

def tool_binary(target, basename):
    """The tool's executable itself, not the hub's Bash shim on Windows.

    Args:
        target: The tool's target.
        basename: The executable's file name on Windows, such as `gobco.exe`.

    Returns:
        The File to run.
    """
    for f in target[DefaultInfo].default_runfiles.files.to_list():
        if f.basename == basename:
            return f
    return target[DefaultInfo].files_to_run.executable

def _module_files(ctx, prefix, entries, verb):
    """Adds the rule's data, go.mod and go.sum to entries, and checks them all."""
    entries = entries + [("data", f) for f in ctx.files.data]
    entries.append(("mod", ctx.file.go_mod))
    if ctx.file.go_sum:
        entries.append(("mod", ctx.file.go_sum))
    for _, f in entries:
        if f.owner.repo_name != "":
            fail("{} is from repository @{}; only files of the main repository can be {}".format(f.short_path, f.owner.repo_name, verb))
        if not f.short_path.startswith(prefix):
            fail("{} is not in the module directory {}".format(f.short_path, prefix or "."))
    return entries

def _proxy_root(ctx):
    """The go_mod_proxy directory of the rule's proxy, or None."""
    if not ctx.attr.proxy:
        return None
    roots = [f for f in ctx.files.proxy if f.basename == "go_mod_proxy.root"]
    if len(roots) != 1:
        fail("proxy must be a go_mod_proxy repository's :proxy target")
    return roots[0]

def go_unit(ctx, verb):
    """Collects the unit of a rule with UNIT_ATTRS, and writes its manifest.

    Args:
        ctx: The rule context.
        verb: What the tool does to the unit's own sources, for messages
            (`mutated`, `covered`).

    Returns:
        A struct: `prefix` (go.mod's directory as a short-path prefix, ""
        at the root), `directory` (the package's short-path directory),
        `pkg` (the package relative to the module, "." for the root),
        `files` (every input File), `manifest` (the manifest File) and
        `args` (the flags that go to the runner: -go, -manifest, -prefix,
        -pkg and -proxy).
    """
    prefix = ctx.file.go_mod.short_path[:-len("go.mod")]
    directories = {t.label.package: True for t in ctx.attr.tests}
    if len(directories) != 1:
        fail("tests must all be in one package; they are in {}".format(sorted(directories)))
    directory = list(directories)[0]
    if prefix and not (directory + "/").startswith(prefix):
        fail("{} is not in the module directory {}".format(directory, prefix))
    pkg = directory[len(prefix):] or "."

    # The package's own sources are the tool's subject, run against its
    # tests; the sources of the packages it depends on are deps.
    entries = []
    for f in depset(transitive = [t[GoSrcsInfo].srcs for t in ctx.attr.tests]).to_list():
        role = "dep"
        if _dirname(f.short_path) == directory:
            role = "test" if f.basename.endswith("_test.go") else "mut"
        entries.append((role, f))
    if not [f for role, f in entries if role == "mut"]:
        fail("the tests in {} reach no source of their own package".format(directory or "."))
    entries = _module_files(ctx, prefix, entries, verb)
    files = [f for _, f in entries]

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "".join([
        "{}\t{}\t{}\n".format(role, f.path, f.short_path[len(prefix):])
        for role, f in entries
    ]))

    sdk = ctx.toolchains[GO_TOOLCHAIN].sdk
    args = ctx.actions.args()
    args.add("-go", sdk.go)
    args.add("-manifest", manifest)
    args.add("-prefix", prefix)
    args.add("-pkg", pkg)
    proxy = _proxy_root(ctx)
    if proxy:
        args.add("-proxy", proxy.dirname)
    return struct(
        prefix = prefix,
        directory = directory,
        pkg = pkg,
        files = files,
        manifest = manifest,
        args = args,
    )

def go_module(ctx, verb):
    """Collects the module of a rule with MODULE_ATTRS and `srcs`, for a test.

    The files are the main-repository sources of `srcs` and of everything
    they depend on, `data`, and go.mod and go.sum. Unlike a unit's, the
    manifest and flags name them by their runfiles paths, relative to the
    directory a test runs in.

    Args:
        ctx: The rule context; `srcs` must carry go_srcs_aspect.
        verb: What the tool does to the sources, for messages (`scanned`).

    Returns:
        A struct: `files` (every input File), `manifest` (the manifest File)
        and `flags` (the runner's -go, -manifest, -prefix and -proxy, as
        strings).
    """
    prefix = ctx.file.go_mod.short_path[:-len("go.mod")]
    entries = [
        ("test" if f.basename.endswith("_test.go") else "src", f)
        for f in depset(transitive = [t[GoSrcsInfo].srcs for t in ctx.attr.srcs]).to_list()
    ]
    entries = _module_files(ctx, prefix, entries, verb)

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "".join([
        "{}\t{}\t{}\n".format(role, f.short_path, f.short_path[len(prefix):])
        for role, f in entries
    ]))

    flags = [
        "-go",
        ctx.toolchains[GO_TOOLCHAIN].sdk.go.short_path,
        "-manifest",
        manifest.short_path,
        "-prefix",
        prefix,
    ]
    proxy = _proxy_root(ctx)
    if proxy:
        flags += ["-proxy", proxy.short_path.rpartition("/")[0]]
    return struct(
        files = [f for _, f in entries],
        manifest = manifest,
        flags = flags,
    )

def sdk_files(ctx):
    """The files of the toolchain's Go SDK a tool running go needs.

    Args:
        ctx: The rule context.

    Returns:
        A depset of Files.
    """
    sdk = ctx.toolchains[GO_TOOLCHAIN].sdk
    return depset([sdk.go, sdk.root_file], transitive = [sdk.srcs, sdk.headers, sdk.tools, sdk.libs])
