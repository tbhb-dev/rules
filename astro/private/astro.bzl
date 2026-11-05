# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Rules that build and check an Astro project with the consumer's astro."""

load("@aspect_rules_js//js:defs.bzl", "js_binary", "js_run_binary")
load("@tbhb_rules//lint:defs.bzl", "tree_check_test")

# Internal: consumers load //:defs.bzl.
visibility("//...")

# astro never phones home or prompts from Bazel. CI makes it fail instead of
# offering to install a missing package.
_ENV = {
    "ASTRO_TELEMETRY_DISABLED": "1",
    "CI": "true",
    "NO_COLOR": "1",
}

# Not yet proved on Windows: the targets are incompatible there, so `bazel
# test //...` skips them.
_NOT_WINDOWS = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
})

def _runfiles_path(label):
    label = native.package_relative_label(label)
    if label.repo_name != "":
        fail("node_modules: {} is from repository @{}; pass the consumer's own npm_link_all_packages target".format(label, label.repo_name))
    if label.name.split("/")[-1] != "node_modules":
        fail("node_modules: {} isn't an npm_link_all_packages target; pass the whole tree, such as //:node_modules".format(label))
    return label.package + "/" + label.name if label.package else label.name

def astro_build(name, srcs, node_modules, **kwargs):
    """Builds a static Astro site with `astro build`.

    The output is a directory, named after the target, holding the built
    site (`index.html` and its assets), ready to upload as it is, for
    example as a GitHub Pages artifact. The site's `astro.config.*` decides
    the rest, such as `site` and `base`; a site that needs a server adapter
    fails, since nothing serves it.

    astro is the consumer's own dependency, from `node_modules`; this module
    doesn't pin it. The build runs in this package of the output tree, with
    the consumer's packages found the way Node finds them, from the nearest
    `node_modules` above it.

    Keep the site in a subpackage, not at the workspace root. Bazel's
    execution root holds the workspace's root files above the output tree,
    and Vite reads a `tsconfig.json` it finds there; a root `tsconfig.json`
    that extends `astro/tsconfigs/*` fails the build there, where no
    `node_modules` sits beside it.

    Args:
        name: Target name, and the output directory.
        srcs: The site's sources: `astro.config.*`, `src/`, `public/`,
            `tsconfig.json` and `package.json`.
        node_modules: The consumer's `npm_link_all_packages` target, which
            must hold astro.
        **kwargs: Passed to `js_run_binary`.
    """
    _runfiles_path(node_modules)
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    js_run_binary(
        name = name,
        tool = Label("//:astro"),
        srcs = srcs + [node_modules],
        args = ["build", name],
        chdir = native.package_name(),
        env = _ENV,
        out_dirs = [name],
        silent_on_success = True,
        **kwargs
    )

def astro_check_test(name, srcs, node_modules, **kwargs):
    """Type-checks an Astro project with `astro check`.

    Runs the consumer's astro, which generates the project's types and then
    runs this module's pinned @astrojs/check and TypeScript over the copy of
    the tree. Errors and warnings fail the check, and so does a tree with
    no `.astro` file outside `node_modules` and dot directories.

    Like tsc, the check reads the project's `tsconfig.json`; extend
    `astro/tsconfigs/strict` there.

    Args:
        name: Target name.
        srcs: The project's files: sources, `astro.config.*`,
            `tsconfig.json`, `package.json`.
        node_modules: The consumer's `npm_link_all_packages` target, which
            must hold astro.
        **kwargs: Passed to `tree_check_test`.
    """
    launcher = name + "_launcher"
    js_binary(
        name = launcher,
        data = [Label("//:launcher_data")] + [Label("//:node_modules/" + p) for p in ["@astrojs/check", "typescript"]] + [node_modules],
        entry_point = Label("//:launcher"),
        env = {"TBHB_NODE_MODULES": _runfiles_path(node_modules)},
        # The launcher's links point into rules_js's stores, and the
        # packages behind them must resolve their own dependencies from
        # there. rules_js's fs patch would keep the link paths instead.
        patch_node_fs = False,
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )

    # The js_binary launcher refuses to start outside its own `bazel run` or
    # test unless BAZEL_BINDIR is set; "." is its documented value for a
    # program that is not a build action.
    env = dict(_ENV)
    env.update(kwargs.pop("env", {}))
    env.setdefault("BAZEL_BINDIR", ".")
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    tree_check_test(
        name = name,
        env = env,
        srcs = srcs,
        tool = ":" + launcher,
        tool_args = ["check"],
        output_guard = "astro check: [0-9]+ .astro files",
        **kwargs
    )

def astro_dev(name, node_modules, **kwargs):
    """A `bazel run` target that serves this package's Astro site with `astro dev`.

    The server runs on the consumer's own sources in the workspace
    (`BUILD_WORKSPACE_DIRECTORY`), so edits reload as they would with a
    local `astro dev`. astro and the site's other packages come from
    `node_modules`: when the workspace has no `node_modules` where that
    target's package declares it, the server links the built tree there
    first. Gitignore `node_modules`, as for any Node project.

    It listens on 127.0.0.1 unless told otherwise, never opens a browser
    and never prompts, so it can run as a background job, and it stops the
    server and exits 0 on SIGINT or SIGTERM. Options come from arguments
    (`bazel run //site:dev -- --port 4321 --base /docs/`) or from the
    `ASTRO_PORT`, `ASTRO_HOST` and `ASTRO_BASE` environment variables; an
    argument wins.

    Args:
        name: Target name.
        node_modules: The consumer's `npm_link_all_packages` target, which
            must hold astro.
        **kwargs: Passed to `js_binary`.
    """
    env = dict(_ENV)
    env.update({
        "TBHB_ASTRO_COMMAND": "dev",
        "TBHB_NODE_MODULES": _runfiles_path(node_modules),
        "TBHB_PACKAGE": native.package_name(),
    })
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    js_binary(
        name = name,
        data = [Label("//:launcher_data"), node_modules],
        entry_point = Label("//:launcher"),
        env = env,
        patch_node_fs = False,
        **kwargs
    )
