# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Whole-tree lint tests, one macro per tool, all built on `tree_check_test`.

Each macro takes `srcs` (usually a `repo_files` target), an optional
`config` and `data`, and a `tool` that defaults to the tbhb_rules pin in the
`@multitool` hub. Any other keyword (`min_files`, `tags`, `size`, ...) goes
to `tree_check_test`.
"""

load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _config_args(config, flag):
    return [flag, "{config}"] if config else []

def gitleaks_test(name, srcs, config = None, tool = Label("@multitool//tools/gitleaks"), **kwargs):
    """Scans the files in `srcs` for secrets with `gitleaks dir`.

    This checks the working tree only. Git history needs `.git`, which a
    sandboxed test cannot see; scan it outside the test graph.

    Args:
        name: Target name.
        srcs: Files to scan.
        config: A gitleaks config such as `.gitleaks.toml`.
        tool: The gitleaks binary.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = tool,
        tool_args = ["dir", "--no-banner", "--redact", "--verbose"] + _config_args(config, "--config") + ["."],
        # gitleaks reports how much it read; zero bytes means it saw nothing.
        output_guard = "scanned ~[1-9][0-9]* bytes",
        **kwargs
    )

def ryl_test(name, srcs, config = None, tool = Label("@multitool//tools/ryl"), **kwargs):
    """Lints YAML with `ryl check --strict`.

    Args:
        name: Target name.
        srcs: Files to check; ryl picks the YAML files by its config.
        config: A ryl config such as `.ryl.toml`. Pass ignore files it
            names (`.rylignore`) in `data`.
        tool: The ryl binary.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = tool,
        tool_args = ["check", "--strict"] + _config_args(config, "-c") + ["-f", "auto", "-o", "-", "."],
        **kwargs
    )

def rumdl_test(name, srcs, config = None, tool = Label("@multitool//tools/rumdl"), **kwargs):
    """Lints Markdown with `rumdl check`.

    rumdl takes the nearest directory holding `.git` as the project root, for
    its reported paths, per-file ignores and cache. The copy gets its own
    `.git`, so a repository above the test's sandbox (such as a `~/.cache`
    under version control, around Bazel's output base) can't capture it.

    Args:
        name: Target name.
        srcs: Files to check.
        config: A rumdl config such as `.rumdl.toml`.
        tool: The rumdl binary.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = tool,
        tool_args = ["check"] + _config_args(config, "--config") + ["."],
        git_root = True,
        **kwargs
    )

def tombi_test(name, srcs, config = None, schemas = {}, tool = Label("@multitool//tools/tombi"), **kwargs):
    """Checks TOML formatting and lints it with tombi, offline.

    Creates `<name>.format` and `<name>.lint` and a `<name>` test suite.
    tombi finds `config` (`tombi.toml`) by searching from the tree root.

    tombi embeds the common SchemaStore schemas, but some of them refer to
    others by URL (pyproject.toml's refers to uv, ruff and pytest), which
    offline it can only read from its cache. With an empty cache those refs
    become warnings, which `--error-on-warnings` fails on. Pass pinned copies
    in `schemas`; the test seeds a private cache with them.

    Args:
        name: Target name.
        srcs: Files to check.
        config: A tombi config such as `tombi.toml`.
        schemas: Dict of schema URL to a label of a pinned copy, for
            example `{"https://www.schemastore.org/uv.json": "@uv_schema//file"}`.
        tool: The tombi binary.
        **kwargs: Passed to both tests; `tags` and `visibility` also go to
            the suite.
    """
    for check, args in [
        ("format", ["format", "--offline", "--check", "--diff"]),
        ("lint", ["lint", "--offline", "--error-on-warnings"]),
    ]:
        tree_check_test(
            name = "{}.{}".format(name, check),
            srcs = srcs,
            config = config,
            tool = tool,
            tool_args = args,
            cache_files = {
                label: "tombi/" + url.replace("://", "/", 1)
                for url, label in schemas.items()
            },
            **kwargs
        )
    native.test_suite(
        name = name,
        tests = [":{}.format".format(name), ":{}.lint".format(name)],
        tags = kwargs.get("tags", []),
        visibility = kwargs.get("visibility"),
    )

def editorconfig_checker_test(name, srcs, config = None, tool = Label("@multitool//tools/editorconfig-checker"), **kwargs):
    """Checks every file in `srcs` against the `.editorconfig` files among them.

    Args:
        name: Target name.
        srcs: Files to check, including the `.editorconfig` files.
        config: An editorconfig-checker config such as
            `.editorconfig-checker.json`.
        tool: The editorconfig-checker binary.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = tool,
        tool_args = _config_args(config, "-config"),
        **kwargs
    )

def actionlint_test(
        name,
        srcs,
        config = None,
        tool = Label("@multitool//tools/actionlint"),
        shellcheck = Label("@multitool//tools/shellcheck"),
        shellcheck_opts = "-o check-extra-masked-returns",
        **kwargs):
    """Lints GitHub Actions workflows under `.github/` with actionlint.

    actionlint checks `run:` blocks with shellcheck, which it looks up on
    PATH; without one those checks vanish silently, so the pinned shellcheck
    is always put on PATH. actionlint finds the project by its `.git`, so the
    copy gets an empty one.

    Args:
        name: Target name.
        srcs: Files to check, including `.github/workflows/`.
        config: An actionlint config such as `.github/actionlint.yaml`.
        tool: The actionlint binary.
        shellcheck: The shellcheck binary actionlint runs.
        shellcheck_opts: `SHELLCHECK_OPTS` for those runs.
        **kwargs: Passed to `tree_check_test`.
    """
    env = dict(kwargs.pop("env", {}))
    env.setdefault("SHELLCHECK_OPTS", shellcheck_opts)
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = tool,
        tool_args = _config_args(config, "-config-file"),
        path_tools = [shellcheck],
        git_root = True,
        env = env,
        **kwargs
    )

def zizmor_test(name, srcs, config = None, tool = Label("@multitool//tools/zizmor"), persona = "pedantic", **kwargs):
    """Audits GitHub Actions workflows under `.github/` with zizmor's offline audits.

    The online audits need the network and a GitHub token, so they do not
    belong in a test.

    Args:
        name: Target name.
        srcs: Files to check, including `.github/`.
        config: A zizmor config such as `.github/zizmor.yml`.
        tool: The zizmor binary.
        persona: zizmor's `--persona`.
        **kwargs: Passed to `tree_check_test`.
    """
    tree_check_test(
        name = name,
        srcs = srcs,
        config = config,
        tool = tool,
        tool_args = ["--persona", persona, "--offline", "--no-progress"] + _config_args(config, "--config") + [".github"],
        **kwargs
    )

# Environment for a pinned git that must not read the host's configuration.
# The template dir is emptied because dugite's compiled-in template path
# does not exist. HOME is already the test's TEST_TMPDIR.
GIT_TEST_ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TEMPLATE_DIR": "",
}

def bats_test(
        name,
        srcs,
        tests,
        tool = Label("@multitool//tools/bats"),
        git = Label("@multitool//tools/git"),
        **kwargs):
    """Runs bats test files over a copy of `srcs`.

    The pinned git is on PATH, isolated from the host's git configuration,
    so tests that create repositories don't depend on the host.

    Args:
        name: Target name.
        srcs: Files the tests need, including the test files themselves;
            usually a `repo_files` target.
        tests: Repository-relative paths of the `.bats` files to run (relative
            to `strip_prefix` when set).
        tool: The bats executable.
        git: The git put on PATH: builtin commands only, and on Linux it
            needs glibc 2.34 or newer.
        **kwargs: Passed to `tree_check_test`.
    """
    if not tests:
        fail("tests must name at least one .bats file")
    env = dict(GIT_TEST_ENV)
    env.update(kwargs.pop("env", {}))
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = tool,
        tool_args = list(tests),
        path_tools = [git] + kwargs.pop("path_tools", []),
        env = env,
        **kwargs
    )
