# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The TypeScript checks: each runs one pinned tool over a copy of the tree.

Every check gets its own js_binary around launch.mjs, whose runfiles hold
only the pinned packages that tool needs and the consumer's `node_modules`.
The launcher links both into the copied tree by their real paths, the
consumer's first, so every package resolves its own dependencies from its
store, and a check never copies a package.
"""

load("@aspect_rules_js//js:defs.bzl", "js_binary")
load("@tbhb_rules//lint:defs.bzl", "tree_check_test")

# Internal: consumers load //:defs.bzl.
visibility("//...")

# The pinned packages each tool needs in its tree. tsc and ESLint take
# vitest too, for the types of the consumer's tests, and knip for its Vitest
# plugin, which loads the consumer's Vitest config.
#
# A list also names every pinned package that a tool's packages import
# without depending on it, such as an optional peer that pnpm leaves
# unlinked. Such an import resolves from this module's top node_modules,
# which holds only the packages some built target listed: without its
# entry here, the check passes after another check has run and fails
# alone. Stryker's core imports typescript to rewrite tsconfig files.
_PACKAGES = {
    "biome": ["@biomejs/biome"],
    "depcruise": ["dependency-cruiser", "typescript"],
    "eslint": ["eslint", "typescript", "typescript-eslint", "vitest"],
    "knip": ["knip", "typescript", "vitest"],
    "pnpm-audit": ["pnpm"],
    "stryker": ["@stryker-mutator/core", "@stryker-mutator/vitest-runner", "@vitest/coverage-v8", "typescript", "vitest"],
    "tsc": ["typescript", "vitest"],
    "vitest": ["@vitest/coverage-v8", "vitest"],
}

# The Workers Vitest integration, for checks with `workers`. It brings
# miniflare and workerd, so only those checks' launchers reference it, and
# only they fetch workerd. V8 coverage can't see into workerd; Istanbul
# instruments the code instead.
_WORKERS = "@cloudflare/vitest-plugin"

def _packages(tool, workers):
    packages = _PACKAGES[tool]
    if not workers:
        return packages
    swapped = ["@vitest/coverage-istanbul" if p == "@vitest/coverage-v8" else p for p in packages]
    return [_WORKERS] + swapped

def _runfiles_path(label):
    label = native.package_relative_label(label)
    if label.repo_name != "":
        fail("node_modules: {} is from repository @{}; pass the consumer's own npm_link_all_packages target".format(label, label.repo_name))
    if label.name.split("/")[-1] != "node_modules":
        fail("node_modules: {} isn't an npm_link_all_packages target; pass the whole tree, such as //:node_modules".format(label))
    return label.package + "/" + label.name if label.package else label.name

def _check(name, tool, srcs, node_modules = [], tool_args = [], tags = [], workers = False, **kwargs):
    launcher = name + "_launcher"
    js_binary(
        name = launcher,
        data = [Label("//:launcher_data")] + [Label("//:node_modules/" + p) for p in _packages(tool, workers)] + node_modules,
        entry_point = Label("//:launcher"),
        env = {
            # The consumer's npm_link_all_packages directories, relative to
            # the main repository's runfiles root.
            "TBHB_NODE_MODULES": ";".join([_runfiles_path(n) for n in node_modules]),
        },
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
    # program that is not a build action, as here, where the test's runner
    # starts it in the copy of the tree.
    env = dict(kwargs.pop("env", {}))
    env.setdefault("BAZEL_BINDIR", ".")
    env.setdefault("NO_COLOR", "1")
    tree_check_test(
        name = name,
        env = env,
        srcs = srcs,
        tool = ":" + launcher,
        tool_args = [tool] + tool_args,
        tags = tags,
        **kwargs
    )

def tsc_test(name, srcs, config = "tsconfig.json", node_modules = [], workers = False, **kwargs):
    """Type-checks a TypeScript project with `tsc --noEmit`.

    tsc is this module's pinned TypeScript. The project's own packages (type
    declarations such as `@cloudflare/workers-types`, and the libraries it
    imports) come from `node_modules`, the consumer's rules_js
    `npm_link_all_packages` target. A project whose config matches no input
    files fails, as tsc itself reports.

    tsc, like Node, also looks for packages and `@types` in every
    `node_modules` above the tree, which a sandbox doesn't have but a
    machine might. Set `compilerOptions.types` so only the listed type
    packages load.

    Args:
        name: Target name.
        srcs: The project's files: sources, tsconfig files, package.json.
        config: The tsconfig file to check, relative to the tree root.
        node_modules: The consumer's `npm_link_all_packages` target, such as `//:node_modules`.
        workers: The project is a Cloudflare Worker tested with
            `@cloudflare/vitest-plugin`: link this module's pinned plugin.
            The plugin brings miniflare and workerd, so the check fetches
            workerd, even for a check that needs only the plugin's types or
            its import in the Vitest config.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "tsc",
        srcs,
        node_modules = node_modules,
        workers = workers,
        tool_args = ["--noEmit", "--pretty", "false", "--project", config],
        **kwargs
    )

def biome_test(name, srcs, config = None, **kwargs):
    """Lints and checks formatting with `biome ci`, which never writes.

    Biome reads `biome.json` or `biome.jsonc` at the tree root unless
    `config` names another. Warnings fail the check, and so does a run that
    reports no file checked.

    Args:
        name: Target name.
        srcs: Files to check, usually a `repo_files` target.
        config: A Biome config file, when not at the tree root.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "biome",
        srcs,
        config = config,
        tool_args = ["ci", "--colors=off", "--error-on-warnings", "--no-errors-on-unmatched"] +
                    (["--config-path={config}"] if config else []) + ["."],
        # Biome's summary counts the files it read; zero means it saw nothing.
        output_guard = "Checked [1-9][0-9]* files?",
        **kwargs
    )

def eslint_test(name, srcs, node_modules = [], workers = False, **kwargs):
    """Lints with ESLint and the consumer's flat config, typically type-aware typescript-eslint.

    The config (`eslint.config.mjs` at the tree root) imports `eslint` and
    `typescript-eslint` as usual; this module links its pins into the tree,
    so the consumer doesn't install them, and typescript-eslint type-checks
    with the same TypeScript as `tsc_test`. The consumer's own packages come
    from `node_modules`. Any error or warning fails the check, and so does a
    tree in which ESLint finds no file to lint. The config must be ESM.

    Args:
        name: Target name.
        srcs: The project's files, the config and tsconfig files among them.
        node_modules: The consumer's `npm_link_all_packages` target, such as `//:node_modules`.
        workers: The project is a Cloudflare Worker tested with
            `@cloudflare/vitest-plugin`: link this module's pinned plugin.
            The plugin brings miniflare and workerd, so the check fetches
            workerd, even for a check that needs only the plugin's types or
            its import in the Vitest config.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "eslint",
        srcs,
        node_modules = node_modules,
        workers = workers,
        output_guard = "eslint: linted [1-9][0-9]* files",
        **kwargs
    )

def knip_test(name, srcs, config = None, node_modules = [], workers = False, **kwargs):
    """Finds unused files, exports and dependencies with knip.

    knip reads `package.json` and its config (`knip.json` and the other
    names knip looks for, or `config`) at the tree root, and the
    consumer's packages from `node_modules`. Tools this module supplies,
    such as `vitest`, `@vitest/coverage-v8` or `typescript-eslint`, aren't
    in the consumer's `package.json`; list the ones its files import in the
    config's `ignoreDependencies`, and enable their knip plugins explicitly.
    A run that analysed no project file fails.

    Args:
        name: Target name.
        srcs: The project's files, `package.json` among them.
        config: A knip config file, when not one knip finds by itself.
        node_modules: The consumer's `npm_link_all_packages` target, such as `//:node_modules`.
        workers: The project is a Cloudflare Worker tested with
            `@cloudflare/vitest-plugin`: link this module's pinned plugin.
            The plugin brings miniflare and workerd, so the check fetches
            workerd, even for a check that needs only the plugin's types or
            its import in the Vitest config.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "knip",
        srcs,
        config = config,
        node_modules = node_modules,
        workers = workers,
        tool_args = ["--no-progress", "--no-config-hints"] + (["--config", "{config}"] if config else []),
        # launch.mjs counts the project files knip analysed.
        output_guard = "knip: analysed [1-9][0-9]* project files",
        **kwargs
    )

def depcruise_test(name, srcs, config = ".dependency-cruiser.cjs", dirs = ["src"], node_modules = [], **kwargs):
    """Checks import boundaries with dependency-cruiser.

    Cruises `dirs` under the rules in `config`, which can forbid cycles,
    imports between layers, or imports of packages a layer mustn't use.
    Any violation of severity `error` fails the check, and so does a cruise
    that found no module.

    Args:
        name: Target name.
        srcs: The project's files.
        config: The dependency-cruiser config, relative to the tree root.
        dirs: The directories to cruise, relative to the tree root.
        node_modules: The consumer's `npm_link_all_packages` target, such as `//:node_modules`.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "depcruise",
        srcs,
        node_modules = node_modules,
        tool_args = ["--config", config, "--output-type", "err-long", "--no-progress"] + dirs,
        # depcruise's summary counts the modules it cruised.
        output_guard = "[1-9][0-9]* modules",
        **kwargs
    )

def vitest_test(name, srcs, config = None, coverage = True, node_modules = [], workers = False, **kwargs):
    """Runs the project's tests once with Vitest.

    Vitest reads its config (`vitest.config.ts` and the other names it looks
    for) at the tree root, or `config`. Tests import `vitest` as usual; this
    module links its pinned Vitest into the tree. With `coverage`, V8
    coverage runs and the config's `test.coverage.thresholds` are enforced.
    A failing test, a missed threshold, or a run in which no test ran
    (skipped and todo tests don't count) fails the check.

    With `workers`, the tests run inside workerd: the config adds
    `cloudflareTest({ wrangler: { configPath } })` from
    `@cloudflare/vitest-plugin` to its plugins. The coverage provider
    becomes Istanbul, since V8 coverage can't see into workerd: the config
    must set `test.coverage.provider` to `"istanbul"`, and the check fails
    with a clear message if it asks for any other provider.

    Args:
        name: Target name.
        srcs: The project's files, tests and config among them.
        config: A Vitest config file, when not one Vitest finds by itself.
        coverage: Collect coverage and enforce the config's thresholds.
        node_modules: The consumer's `npm_link_all_packages` target, such as `//:node_modules`.
        workers: The project is a Cloudflare Worker tested with
            `@cloudflare/vitest-plugin`: link this module's pinned plugin.
            The plugin brings miniflare and workerd, so the check fetches
            workerd, even for a check that needs only the plugin's types or
            its import in the Vitest config.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "vitest",
        srcs,
        config = config,
        node_modules = node_modules,
        workers = workers,
        tool_args = (["--coverage"] if coverage else []) + (["--workers"] if workers else []) + (["--config={config}"] if config else []),
        output_guard = "vitest: ran [1-9][0-9]* tests",
        **kwargs
    )

def stryker_test(name, srcs, config = None, node_modules = [], workers = False, **kwargs):
    """Mutation-tests the project with Stryker and the Vitest runner.

    Stryker reads its config (`stryker.config.mjs` and the other names it
    looks for) at the tree root, or `config`. Set `testRunner: "vitest"`,
    `plugins: ["@stryker-mutator/vitest-runner"]` (Stryker's default plugin
    scan looks beside its own install, which holds only its core) and a
    `thresholds.break` score; a mutation score below it fails the check, and
    so does a run that made no mutant. Set `concurrency` to the CPUs the
    test may use, and tag the test `cpu:N` to match. This module links its
    pinned Stryker, Vitest runner, Vitest and TypeScript into the tree.

    On Windows, Stryker's Babel packages have store paths close to the
    260-character limit, and under Bazel's default output root they pass
    it. Set a short root there, such as `startup --output_user_root=C:/b`.

    Args:
        name: Target name.
        srcs: The project's files, tests and configs among them.
        config: A Stryker config file, when not one Stryker finds by itself.
        node_modules: The consumer's `npm_link_all_packages` target, such as `//:node_modules`.
        workers: The project is a Cloudflare Worker tested with
            `@cloudflare/vitest-plugin`: link this module's pinned plugin.
            The plugin brings miniflare and workerd, so the check fetches
            workerd, even for a check that needs only the plugin's types or
            its import in the Vitest config.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "stryker",
        srcs,
        config = config,
        node_modules = node_modules,
        workers = workers,
        tool_args = (["--workers"] if workers else []) + ["run"] + (["{config}"] if config else []),
        # Stryker reports how many mutants it made; none means nothing was tested.
        output_guard = "with [1-9][0-9]* mutant\\(s\\)",
        **kwargs
    )

def pnpm_audit_test(name, srcs, args = [], tags = [], **kwargs):
    """Audits the consumer's pnpm lock against the npm advisory database.

    Needs the network and gives a different answer as advisories are
    published, so it is tagged `requires-network`, `external` (never cached)
    and `manual` (not part of `//...`); run it explicitly, or use the
    `bazel run @tbhb_rules_typescript//:pnpm_audit` target. Any advisory
    fails it.

    Args:
        name: Target name.
        srcs: Files including the root package.json, pnpm-lock.yaml and, if
            there is one, pnpm-workspace.yaml, where pnpm 11 and later read
            overrides from.
        args: Extra `pnpm audit` options.
        tags: More tags.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        "pnpm-audit",
        srcs,
        tool_args = ["--audit-level", "low"] + args,
        tags = ["requires-network", "external", "manual"] + tags,
        **kwargs
    )
