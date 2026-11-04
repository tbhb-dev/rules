# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Python lint and test checks over a copy of the tree.

Every macro builds on tbhb_rules' `tree_check_test`: the tool runs at the
root of a dereferenced copy of `srcs`, laid out at repository-relative
paths, so it reads the project's configuration (pyproject.toml) as it would
in a checkout. Tools come from the locked environment (`@tbhb_python//:env`
by default), so their versions are the ones uv.lock pins.

The lint checks pick the Python files themselves: `*.py` and `*.pyi`, and
extensionless scripts whose first line is a python or `uv run` shebang (PEP
723 scripts among them). A tree with no Python file fails. A PEP 723
script's own dependencies are not installed separately: they must be
satisfied by the workspace environment (its members and locked groups), and
a script that needs anything else fails the type check on the import.
"""

load("@tbhb_rules//lint:defs.bzl", "tree_check_test")
load(":tool.bzl", "DEFAULT_ENV", "TOOLS_ENV", "python_tool")

# Internal: consumers load //:defs.bzl.
visibility("//...")

_ENV = DEFAULT_ENV

def _missing_coverage_impl(ctx):
    fail("{}: pytest_test needs `coverage`, the packages or paths whose branch coverage it measures, such as coverage = [\"mypkg\"]. Set coverage = None only for a test with no first-party code to measure.".format(ctx.label))

# Stands in for a pytest_test that names nothing to measure. A macro's fail()
# is a loading error that aborts the whole package; failing in a rule's
# implementation is an analysis error of this one target, which a test can
# expect.
_missing_coverage_test = rule(
    implementation = _missing_coverage_impl,
    test = True,
)

def _check(name, srcs, tool, tool_args, select = True, exclude = [], chdir = "", python_env = _ENV, main = None, tool_attrs = {}, **kwargs):
    python_tool(
        name = name + ".tool",
        tool = tool,
        main = main,
        select = select,
        exclude = exclude,
        chdir = chdir,
        python_env = python_env,
        tags = ["manual"],
        visibility = ["//visibility:private"],
        testonly = True,
        **tool_attrs
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = tool_args,
        **kwargs
    )

def ruff_test(name, srcs, args = [], exclude = [], python_env = _ENV, **kwargs):
    """Lints the Python files in `srcs` with `ruff check`.

    Formatting is checked by `format_test` with `@tbhb_rules_python//:ruff`
    among its formatters.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target.
        args: Extra ruff options.
        exclude: fnmatch patterns of tree-relative paths to skip.
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "ruff", ["check", "--no-cache", "--force-exclude"] + args, exclude = exclude, python_env = python_env, **kwargs)

def pyrefly_test(name, srcs, args = [], exclude = [], python_env = _ENV, **kwargs):
    """Type-checks the Python files in `srcs` with `pyrefly check`.

    pyrefly finds the locked environment's packages and the workspace
    members' sources through the interpreter, which the launcher puts on
    PATH.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target.
        args: Extra pyrefly options.
        exclude: fnmatch patterns of tree-relative paths to skip.
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "pyrefly", ["check"] + args, exclude = exclude, python_env = python_env, **kwargs)

def pylint_test(name, srcs, args = [], exclude = [], python_env = _ENV, **kwargs):
    """Runs pylint over the Python files in `srcs`, configured by pyproject.toml.

    All files go to one pylint run, so cross-file checks such as
    duplicate-code see the whole tree.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target.
        args: Extra pylint options.
        exclude: fnmatch patterns of tree-relative paths to skip.
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "pylint", args, exclude = exclude, python_env = python_env, **kwargs)

def vulture_test(name, srcs, args = [], exclude = [], python_env = _ENV, **kwargs):
    """Finds dead code in the Python files in `srcs` with vulture.

    The whole program goes to one run, so a use in one file keeps a
    definition in another alive. `[tool.vulture]` in pyproject.toml applies;
    the selected files replace its `paths`, so list allowlist files there
    or keep them among the Python files.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target.
        args: Extra vulture options.
        exclude: fnmatch patterns of tree-relative paths to skip.
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "vulture", args, exclude = exclude, python_env = python_env, **kwargs)

def complexipy_test(name, srcs, args = [], exclude = [], python_env = _ENV, **kwargs):
    """Fails on functions over the cognitive complexity ceiling, with complexipy.

    `[tool.complexipy]` in pyproject.toml sets the ceiling.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target.
        args: Extra complexipy options.
        exclude: fnmatch patterns of tree-relative paths to skip.
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "complexipy", args, exclude = exclude, python_env = python_env, **kwargs)

def bandit_test(name, srcs, args = ["-q"], exclude = [], python_env = _ENV, **kwargs):
    """Scans the Python files in `srcs` for security issues with bandit.

    Args:
        name: Target name.
        srcs: Files to search, usually a `repo_files` target.
        args: bandit options. Add `-c pyproject.toml` when its
            `[tool.bandit]` table should apply.
        exclude: fnmatch patterns of tree-relative paths to skip, such as
            `**/test_*.py` (asserts are pytest's API).
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "bandit", args, exclude = exclude, python_env = python_env, **kwargs)

def deptry_test(name, srcs, roots = ["."], args = [], chdir = "", python_env = _ENV, **kwargs):
    """Finds undeclared, unused and misplaced dependencies with deptry.

    deptry compares the project's declared dependencies (`[project]`,
    `[dependency-groups]`) with the third-party modules its Python files
    import, and fails on any finding: a missing dependency (DEP001), an unused
    one (DEP002), a transitive one used directly (DEP003) or a development
    one imported by code that ships (DEP004). It maps modules to packages
    through the locked environment, so the environment must provide deptry
    and every declared dependency, and it takes its configuration from
    `[tool.deptry]` in the pyproject.toml of the directory it runs from.

    It checks one project: the pyproject.toml in `chdir` against the Python
    under its `roots`. A uv workspace takes one target per member, each with
    its `chdir`; the members are installed in the environment, so a member's
    dependency on another is a dependency like any other. deptry reads
    `.py` and `.ipynb` files only, so extensionless scripts are not
    checked, and a project with no Python file has nothing to find and
    passes. It skips a `tests` directory at the top of a root by default;
    name colocated or nested test files in `--extend-exclude` (a regular
    expression matched from the start of the path).

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        roots: Directories, relative to `chdir`, to scan. A `src` layout
            scans `["src"]`: the modules directly under a root are the
            project's own, not third-party imports.
        args: Extra deptry options, such as `--extend-exclude`.
        chdir: Directory, relative to the tree root, of the project to check.
        python_env: The Python environment, which must provide deptry.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(name, srcs, "deptry", ["--no-ansi"] + args + roots, select = False, chdir = chdir, python_env = python_env, **kwargs)

def pytest_test(
        name,
        srcs,
        args = [],
        coverage = [],
        chdir = "",
        python_env = _ENV,
        vale_config = ".vale.ini",
        vale_packages = {},
        **kwargs):
    """Runs pytest over a copy of the tree, with branch coverage at 100%.

    pytest reads its configuration (testpaths, addopts) from the
    pyproject.toml of the directory it runs from, `chdir` relative to the
    tree root. The workspace members' source roots are importable, and the
    copy keeps the repository layout, so tests that find data by walking up
    from their own file still do.

    Coverage is measured in the test with pytest-cov, which the environment
    must provide, and the floor is 100% branch coverage (branches and
    lines). Consumers don't configure the floor. A test must say what to
    measure: with no `coverage`, the target fails at analysis time, naming
    this argument.

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        args: Extra pytest arguments.
        coverage: Packages or paths to measure (`--cov` values), required:
            list every first-party package or path the tests cover. Set it
            to `None` only for a test with no first-party code to measure,
            such as one that drives an external tool against fixture files.
            An empty list fails like an omitted argument.
        chdir: Directory, relative to the tree root, to run pytest from.
        python_env: The Python environment.
        vale_config: With `vale_packages`, the Vale config whose StylesPath
            the packages are synced into, relative to the tree root.
        vale_packages: Vale package archives, {package name: label}, synced
            into the copy before pytest runs, for tests that drive vale
            against the repository's configuration. vale itself must be on
            PATH (`path_tools`).
        **kwargs: Passed to `tree_check_test`.
    """
    if coverage == []:
        _missing_coverage_test(name = name, tags = kwargs.get("tags", []), testonly = True)
        return
    cov_args = []
    if coverage:
        cov_args = ["--cov=" + c for c in coverage] + [
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=100",
        ]
    pytest_args = ["-p", "no:cacheprovider", "--junitxml={env:XML_OUTPUT_FILE}"] + cov_args + args
    if not vale_packages:
        _check(name, srcs, "pytest", pytest_args, select = False, chdir = chdir, python_env = python_env, **kwargs)
        return
    python_tool(
        name = name + ".tool",
        tool = "pytest",
        chdir = chdir,
        python_env = python_env,
        tags = ["manual"],
        visibility = ["//visibility:private"],
        testonly = True,
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = Label(":vale_sync_then.sh"),
        tool_args = [vale_config, name + ".tool"] + pytest_args,
        path_tools = kwargs.pop("path_tools", []) + [":{}.tool".format(name)],
        cache_files = {
            label: "vale/packages/{}/{}.zip".format(("00" + str(index))[-3:], package)
            for index, (package, label) in enumerate(vale_packages.items())
        },
        **kwargs
    )

def pip_audit_test(name, srcs, args = [], python_env = _ENV, tags = [], **kwargs):
    """Audits the locked dependencies against the advisory database.

    Needs the network and gives a different answer as advisories are
    published, so it is tagged `requires-network`, `external` (never cached)
    and `manual` (not part of `//...`); run it explicitly or use `pip_audit`.

    Args:
        name: Target name.
        srcs: Files including the root pyproject.toml and uv.lock, and each
            member's pyproject.toml.
        args: Extra pip-audit options.
        python_env: The Python environment, which must provide pip-audit.
        tags: More tags.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        srcs,
        "python",
        args,
        select = False,
        main = Label(":pip_audit.py"),
        python_env = python_env,
        tags = ["requires-network", "external", "manual"] + tags,
        **kwargs
    )

def pip_audit(name, args = [], python_env = _ENV, **kwargs):
    """`bazel run` target that audits the workspace's uv.lock.

    Args:
        name: Target name.
        args: Extra pip-audit options.
        python_env: The Python environment, which must provide pip-audit.
        **kwargs: Passed to the underlying `python_tool`.
    """
    python_tool(
        name = name,
        main = Label(":pip_audit.py"),
        python_env = python_env,
        args = args,
        **kwargs
    )

def import_linter_test(name, srcs, config = None, chdir = "", python_env = _ENV, **kwargs):
    """Checks the import contracts of the tree with import-linter.

    import-linter comes from this module's own pins, not the consumer's
    lock: it parses the sources and imports nothing. The contracts are the
    consumer's, in `[tool.importlinter]` of the pyproject.toml where it runs
    or in `.importlinter`; `config` names another file. The root packages
    resolve against the tree root (so a namespace package such as `tools`
    works) and the workspace members' source roots from `python_env`, src
    and flat layouts alike. The test fails when no contract is defined or
    no module was analysed, as well as on a broken contract.

    Only importable modules are analysed: extensionless scripts (PEP 723
    scripts among them) are not modules, so their imports are not checked;
    keep their logic in a module and the script a thin entry point.

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        config: A contracts file, relative to where it runs.
        chdir: Directory, relative to the tree root, to run from.
        python_env: The environment whose workspace members' source roots
            are importable.
        **kwargs: Passed to `tree_check_test`.
    """
    _check(
        name,
        srcs,
        "python",
        ["--config", config] if config else [],
        select = False,
        chdir = chdir,
        main = Label(":import_linter.py"),
        python_env = TOOLS_ENV,
        tool_attrs = {
            "extra_source_roots": ["."],
            "source_roots_from": python_env,
        },
        **kwargs
    )
