# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Rules that build, test and serve a Storybook for one framework."""

load("@aspect_rules_js//js:defs.bzl", "js_binary")
load("@tbhb_rules//lint:defs.bzl", "tree_check_test")

# Internal: consumers load //:defs.bzl.
visibility("//...")

# The frameworks a Storybook can use, by the name the rules take, and the
# pinned framework package behind each.
FRAMEWORKS = {
    # A community framework, not one of Storybook's own.
    "astro": "@storybook-astro/framework",
    "html": "@storybook/html-vite",
    "react": "@storybook/react-vite",
    "web-components": "@storybook/web-components-vite",
}

# The renderer libraries each framework needs from the consumer's own
# node_modules; this module doesn't pin them.
RENDERERS = {
    "astro": ["astro"],
    "html": [],
    "react": ["react", "react-dom"],
    "web-components": ["lit"],
}

# Storybook never phones home or prompts from Bazel.
_ENV = {
    "CI": "true",
    "NO_COLOR": "1",
    "STORYBOOK_DISABLE_TELEMETRY": "1",
}

# Not yet proved on Windows: the targets are incompatible there, so `bazel
# test //...` skips them.
_NOT_WINDOWS = select({
    Label("@platforms//os:windows"): [Label("@platforms//:incompatible")],
    "//conditions:default": [],
})

def framework_error(framework):
    """Why `framework` can't be a rule's `framework`, or None when it can.

    Args:
        framework: A string.

    Returns:
        An error message, or None.
    """
    if framework in FRAMEWORKS:
        return None
    return "framework: {} isn't one of {}".format(repr(framework), ", ".join(sorted(FRAMEWORKS)))

def node_modules_error(label):
    """Why `label` can't be a rule's `node_modules`, or None when it can.

    It must be the consumer's own `npm_link_all_packages` target, in the
    main repository: the launcher finds that tree in the runfiles by its
    package path.

    Args:
        label: A Label.

    Returns:
        An error message, or None.
    """
    if label.repo_name != "":
        return "node_modules: {} is from repository @{}; pass the consumer's own npm_link_all_packages target".format(label, label.repo_name)
    if label.name.split("/")[-1] != "node_modules":
        return "node_modules: {} isn't an npm_link_all_packages target; pass the whole tree, such as //:node_modules".format(label)
    return None

def node_modules_path(label):
    """The runfiles path of a valid `node_modules` label, relative to the main repository.

    Args:
        label: A Label that node_modules_error accepts.

    Returns:
        The path, such as `node_modules` or `site/node_modules`.
    """
    return label.package + "/" + label.name if label.package else label.name

def _validated(framework, node_modules):
    error = framework_error(framework)
    if error:
        fail(error)
    label = native.package_relative_label(node_modules)
    error = node_modules_error(label)
    if error:
        fail(error)
    return node_modules_path(label)

def _launcher_env(framework, config_dir, node_modules_rel):
    return {
        "TBHB_CONFIG_DIR": config_dir,
        "TBHB_FRAMEWORK": framework,
        "TBHB_FRAMEWORK_PACKAGE": FRAMEWORKS[framework],
        "TBHB_NODE_MODULES": node_modules_rel,
        "TBHB_RENDERERS": ",".join(RENDERERS[framework]),
    }

def _launcher(name, framework, config_dir, node_modules, node_modules_rel, testonly, env = {}, data = []):
    js_binary(
        name = name,
        data = [
            Label("//:launcher_data"),
            Label("//:node_modules"),
            node_modules,
        ] + data,
        entry_point = Label("//:launcher"),
        env = _launcher_env(framework, config_dir, node_modules_rel) | env,
        # The launcher's links point into rules_js's stores, and the
        # packages behind them must resolve their own dependencies from
        # there. rules_js's fs patch would keep the link paths instead.
        patch_node_fs = False,
        tags = ["manual"],
        testonly = testonly,
        visibility = ["//visibility:private"],
    )

def tree_path(path, strip_prefix):
    """A source's path in the copy of the project, and an error, if any.

    Args:
        path: The file's short path.
        strip_prefix: The package the project is in, or "" for the root.

    Returns:
        (path in the tree, None), or (None, error) for a file outside the
        project's package.
    """
    if not strip_prefix:
        return path, None
    if not path.startswith(strip_prefix + "/"):
        return None, "srcs: {} isn't under this package, {}".format(path, strip_prefix)
    return path[len(strip_prefix) + 1:], None

def _tree_path(file, strip_prefix):
    path, error = tree_path(file.short_path, strip_prefix)
    if error:
        fail(error)
    return path

def _storybook_build_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join(["{}\t{}\n".format(f.path, _tree_path(f, ctx.attr.strip_prefix)) for f in ctx.files.srcs]),
    )
    ctx.actions.run(
        executable = ctx.executable.tool,
        arguments = ["build", out.path, manifest.path],
        inputs = depset([manifest], transitive = [depset(ctx.files.srcs)]),
        outputs = [out],
        env = _ENV | {"BAZEL_BINDIR": ctx.bin_dir.path},
        mnemonic = "StorybookBuild",
        progress_message = "Building Storybook %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

_storybook_build = rule(
    implementation = _storybook_build_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "strip_prefix": attr.string(),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
    },
)

def storybook_build(name, srcs, framework, node_modules, config_dir = ".storybook", **kwargs):
    """Builds a static Storybook with `storybook build`.

    The output is a directory, named after the target, holding the built
    Storybook (`index.html`, `iframe.html` and their assets). Every path in
    it is relative, so it serves as it is from any base path, such as
    `/storybook/react/` of a GitHub Pages site. It holds no `project.json`,
    whose build time would make two builds of the same sources differ.

    The Storybook is this package's: `srcs` sit at their paths relative to
    it, and `config_dir` holds its `main` and `preview` configs. The
    `framework` attribute decides the framework; a `framework` in the main
    config keeps only its options. The a11y and Vitest addons are always
    added. The renderer libraries (react and react-dom for react, lit for
    web-components, astro for astro) come from `node_modules`.

    Args:
        name: Target name, and the output directory.
        srcs: The Storybook's files: its config directory, stories and the
            sources they import, and `package.json`.
        framework: One of `astro`, `html`, `react` or `web-components`.
        node_modules: The consumer's `npm_link_all_packages` target.
        config_dir: The config directory, relative to this package.
        **kwargs: Passed to the build rule.
    """
    rel = _validated(framework, node_modules)
    tool = name + "_launcher"
    _launcher(tool, framework, config_dir, node_modules, rel, testonly = kwargs.get("testonly", False))
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    _storybook_build(
        name = name,
        srcs = srcs,
        strip_prefix = native.package_name(),
        tool = ":" + tool,
        **kwargs
    )

def storybook_test(name, srcs, framework, node_modules, config_dir = ".storybook", **kwargs):
    """Runs every story as a test in the pinned Chromium.

    Vitest's browser mode renders each story, runs its play function, and
    checks the result for accessibility with axe's defaults: a violation
    fails the story. The consumer's preview can't change that: its
    `parameters.a11y` (`test`, `disable`, and axe's `config`, `options`
    and `context`) gives way to `test: "error"`, and its `a11y.manual`
    global to `false`. Only a story's or a component's own
    `parameters.a11y` or `globals.a11y` can relax the check. A run in which
    no story ran fails too.

    The project is this package's, as for storybook_build.

    Args:
        name: Target name.
        srcs: The Storybook's files, as for storybook_build.
        framework: One of `astro`, `html`, `react` or `web-components`.
        node_modules: The consumer's `npm_link_all_packages` target.
        config_dir: The config directory, relative to this package.
        **kwargs: Passed to `tree_check_test`.
    """
    rel = _validated(framework, node_modules)
    launcher = name + "_launcher"
    _launcher(
        launcher,
        framework,
        config_dir,
        node_modules,
        rel,
        testonly = True,
        env = {
            "TBHB_PLAYWRIGHT_BROWSERS": "$(rlocationpath @tbhb_rules_playwright//:chromium)",
            "TBHB_PLAYWRIGHT_HELPER": "$(rlocationpath @tbhb_rules_playwright//:browsers_path)",
        },
        data = [
            Label("@tbhb_rules_playwright//:browsers_path"),
            Label("@tbhb_rules_playwright//:chromium"),
        ],
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
        strip_prefix = native.package_name(),
        tool = ":" + launcher,
        tool_args = ["test"],
        output_guard = "storybook test: ran [0-9]+ stories",
        **kwargs
    )

def storybook_dev(name, framework, node_modules, config_dir = ".storybook", **kwargs):
    """A `bazel run` target that serves this package's Storybook with `storybook dev`.

    The server runs on the consumer's own sources in the workspace
    (`BUILD_WORKSPACE_DIRECTORY`), so edits reload as they would with a
    local `storybook dev`, and serves the Storybook under a base path, such
    as `/storybook/react/`, so several can sit behind one reverse proxy at
    the paths they'd have on a site. Its generated config and Storybook's
    cache go in a temporary directory of the run's own, outside the
    workspace, so concurrent runs don't collide.

    In the workspace it writes one thing: where `node_modules`' package
    declares that tree (`sb/node_modules` for `//sb:node_modules`), a
    directory linking each of the tree's packages into Bazel's output tree,
    remade each run, unless a directory or link of the consumer's own is
    there. Gitignore and bazelignore it, as for a local `pnpm install`.

    It listens on 127.0.0.1:6006 at `/` unless told otherwise, never opens
    a browser and never prompts, so it can run as a background job, and it
    stops the server and exits 0 on SIGINT or SIGTERM. Options come from
    arguments (`bazel run //sb:dev -- --port 6006 --base /storybook/react/`)
    or from the `STORYBOOK_PORT`, `STORYBOOK_HOST` and `STORYBOOK_BASE`
    environment variables; an argument wins.

    Args:
        name: Target name.
        framework: One of `astro`, `html`, `react` or `web-components`.
        node_modules: The consumer's `npm_link_all_packages` target.
        config_dir: The config directory, relative to this package.
        **kwargs: Passed to `js_binary`.
    """
    rel = _validated(framework, node_modules)
    env = dict(_ENV)
    env.update(_launcher_env(framework, config_dir, rel))
    env.update({
        "TBHB_PACKAGE": native.package_name(),
        "TBHB_STORYBOOK_COMMAND": "dev",
    })
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    js_binary(
        name = name,
        data = [
            Label("//:launcher_data"),
            Label("//:node_modules"),
            node_modules,
        ],
        entry_point = Label("//:launcher"),
        env = env,
        patch_node_fs = False,
        **kwargs
    )
