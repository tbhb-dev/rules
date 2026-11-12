# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Vale prose lint against pinned style packages, and a sync for editors."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _index(index):
    return ("00" + str(index))[-3:]

def _cache_files(packages):
    # vale names a package by its archive's file name, and later packages
    # override earlier ones, so each archive lands as NNN/<name>.zip and the
    # runner passes them to `vale sync` in that order.
    return {
        label: "vale/packages/{}/{}.zip".format(_index(index), package)
        for index, (package, label) in enumerate(packages.items())
    }

def vale_test(
        name,
        srcs,
        config = ".vale.ini",
        packages = {},
        include = ["*.md"],
        tool = Label("@tbhb_rules_vale//:vale"),
        **kwargs):
    """Lints prose with Vale, offline, against pinned style packages.

    `vale sync` downloads the packages a config names; a test cannot, so the
    packages come in as pinned archives instead (`http_file` with a
    `sha256`, one per `Packages` URL in the config), and the test syncs from
    them with vale's own `vale sync`. The files to lint are picked before the sync, so the synced styles
    are never linted themselves. Keep the synced directories out of `srcs`.

    The shared public vocabulary is added alongside the project vocabularies
    in the scratch tree. Accepted entries also accept a possessive suffix.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target. It must include
            the project's own styles and vocabularies under StylesPath.
        config: The Vale config, such as `.vale.ini`.
        packages: Dict of package name (the archive's file name without
            `.zip`, such as `Google`) to the label of its archive, in the
            order of the config's `Packages` list.
        include: bash `[[ == ]]` patterns, matched against each file's
            tree-relative path and its basename, of the files to lint.
        tool: The vale binary. Its basename must be `vale`.
        **kwargs: Passed to `tree_check_test`.
    """
    cache_files = dict(kwargs.pop("cache_files", {}))
    cache_files[Label("//lint/vocabulary:words.txt")] = "vale/words.txt"
    include_args = []
    for pattern in include:
        include_args += ["--include", pattern]
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = Label(":vale.sh"),
        tool_args = ["{config}"] + include_args,
        path_tools = [tool],
        cache_files = cache_files | _cache_files(packages),
        **kwargs
    )

def _vale_sync_impl(ctx):
    if len(ctx.files.packages) != len(ctx.attr.package_names):
        fail("vale_sync: each package needs exactly one archive file")
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@CONFIG@@": shell.quote(ctx.file.config.short_path),
            "@@NAMES@@": " ".join([shell.quote(n) for n in ctx.attr.package_names]),
            "@@PACKAGES@@": " ".join([shell.quote(f.short_path) for f in ctx.files.packages]),
            "@@VALE@@": ctx.executable.tool.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.tool] + ctx.files.packages)
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_vale_sync = rule(
    implementation = _vale_sync_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """`bazel run` target that writes the pinned Vale packages into the
workspace's StylesPath, the same unpacking `vale sync` does from the
config's URLs, for editors and for running vale by hand.""",
    attrs = SHELL_ATTRS | {
        "config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The Vale config whose StylesPath receives the packages.",
        ),
        "package_names": attr.string_list(
            mandatory = True,
            doc = "Package names, one per archive in `packages`.",
        ),
        "packages": attr.label_list(
            allow_files = [".zip"],
            mandatory = True,
            doc = "Package archives, in the order of the config's `Packages` list.",
        ),
        "tool": attr.label(
            default = Label("@tbhb_rules_vale//:vale"),
            executable = True,
            cfg = "target",
            doc = "The vale binary.",
        ),
        "_runner": attr.label(
            default = Label(":vale_sync.sh.tpl"),
            allow_single_file = True,
        ),
    },
)

def vale_sync(name, config, packages, **kwargs):
    """`bazel run` target that writes pinned Vale packages into StylesPath.

    The same unpacking `vale sync` does from the config's URLs, from the
    archives `vale_test` uses, for editors and for running vale by hand.

    Args:
        name: Target name.
        config: The Vale config whose StylesPath receives the packages.
        packages: Dict of package name to archive label, as for `vale_test`.
        **kwargs: Passed to the underlying rule (`tool`, `tags`, ...).
    """
    _vale_sync(
        name = name,
        config = config,
        package_names = packages.keys(),
        packages = packages.values(),
        **kwargs
    )
