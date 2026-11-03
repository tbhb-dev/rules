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
load(":env.bzl", "python_tool")

# Internal: consumers load //:defs.bzl.
visibility("//...")

_ENV = Label("@tbhb_python//:env")

def _check(name, srcs, tool, tool_args, select = True, exclude = [], chdir = "", python_env = _ENV, main = None, **kwargs):
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

def pytest_test(
        name,
        srcs,
        args = [],
        coverage = [],
        coverage_floor = 100,
        chdir = "",
        python_env = _ENV,
        **kwargs):
    """Runs pytest over a copy of the tree, optionally with a coverage floor.

    pytest reads its configuration (testpaths, addopts) from the
    pyproject.toml of the directory it runs from, `chdir` relative to the
    tree root. The workspace members' source roots are importable, and the
    copy keeps the repository layout, so tests that find data by walking up
    from their own file still do. Coverage is measured in the test with
    pytest-cov, which the environment must provide, with branch coverage
    on, and fails below `coverage_floor` percent.

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        args: Extra pytest arguments.
        coverage: Packages or paths to measure (`--cov` values). Empty
            turns coverage off.
        coverage_floor: The minimum total coverage, in percent.
        chdir: Directory, relative to the tree root, to run pytest from.
        python_env: The Python environment.
        **kwargs: Passed to `tree_check_test`.
    """
    cov_args = []
    if coverage:
        cov_args = ["--cov=" + c for c in coverage] + [
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under={}".format(coverage_floor),
        ]
    _check(
        name,
        srcs,
        "pytest",
        ["-p", "no:cacheprovider", "--junitxml={env:XML_OUTPUT_FILE}"] + cov_args + args,
        select = False,
        chdir = chdir,
        python_env = python_env,
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
