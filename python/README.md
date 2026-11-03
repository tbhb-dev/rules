# tbhb_rules_python

Python checks for tbhb-dev repositories, driven by the repository's own `uv.lock`. A nested module of tbhb-dev/rules, released on its own. It depends on `tbhb_rules` for `tree_check_test`, the formatter API and the mutation gate.

Load only `@tbhb_rules_python//:defs.bzl` and `@tbhb_rules_python//:extensions.bzl`. Everything under `private/` is internal.

## The environment

```starlark
bazel_dep(name = "tbhb_rules_python", version = "0.0.0", dev_dependency = True)

python = use_extension("@tbhb_rules_python//:extensions.bzl", "python", dev_dependency = True)
python.project()  # //:pyproject.toml and //:uv.lock by default
```

The extension builds `@tbhb_python//:env`, which is what `uv sync` gives a developer:

- The interpreter is the version in `.python-version`, or the version `python_version` sets. uv installs it from its own download metadata and verifies the archive's sha256.
- The packages are every package `uv.lock` pins, for every workspace member and every dependency group, installed with `uv sync --frozen`. uv verifies each one against the lock's hashes.

The pinned uv is in `private/versions.bzl`. The environment is rebuilt only when the lock, a `pyproject.toml` or `.python-version` changes.

Workspaces need no per-repository setup. The members come from the lock's `[manifest]`:

- a single project, as in ascm;
- a virtual root with members, as in ops;
- a package root with members.

The members themselves are not installed. Their source roots are put on the path instead: `<member>/src` when it exists, the member directory otherwise. A virtual project has none. So a test imports the copy of the source it runs over, not an installed snapshot.

## Checks

```starlark
load("@tbhb_rules_python//:defs.bzl", "pytest_test", "pyrefly_test", "ruff_test")

ruff_test(name = "ruff_test", srcs = ["//:repo_files"])
pyrefly_test(name = "pyrefly_test", srcs = ["//:repo_files"])
pytest_test(name = "pytest_test", srcs = ["//:repo_files"], coverage = ["tools"])
```

Each check is a `tree_check_test`. Its tool runs at the root of a dereferenced copy of `srcs`, laid out at repository-relative paths, so `pyproject.toml` configures it as it would in a checkout. Tests that find data by walking up from their own file still find it.

- **Lint**: `ruff_test`, `pyrefly_test`, `pylint_test`, `vulture_test`, `complexipy_test` and `bandit_test`.
  - Each selects the Python files itself: `*.py` and `*.pyi`, plus extensionless scripts whose first line is a python or `uv run` shebang.
  - `exclude` takes fnmatch patterns.
  - A tree with no Python file fails.
- **PEP 723 scripts**: their inline dependencies are not installed separately. They must be met by the workspace environment, that is its members and locked groups. A script that needs anything else fails the type check on the import.
- **`pytest_test`**: runs pytest from `chdir`, with that directory's pytest configuration.
  - `coverage` turns on pytest-cov, with branch coverage and a `--cov-fail-under` floor (`coverage_floor`, default 100). The environment must provide pytest-cov.
  - The JUnit report goes to Bazel's `XML_OUTPUT_FILE`.
- **Formatting**: `@tbhb_rules_python//:ruff` is a tbhb_rules `formatter` for `ruff format`. It is offered every file and keeps the Python ones, so extensionless scripts are formatted too.
- **`mutmut_test`**: runs mutmut over a copy of the tree in a cached action, from `chdir`, whose `pyproject.toml` holds `[tool.mutmut]`. It gates the result with tbhb_rules' `mutation_gate_test`, so every mutant must be killed. Mark an equivalent mutant with `# pragma: no mutate` and a reason.
- **pip-audit**: `pip_audit` is a `bazel run` target that audits the lock. `pip_audit_test` is the same check as a test tagged `requires-network`, `external` and `manual`, because advisories change without any input changing.

`python_tool` makes any tool of the environment an executable: the interpreter (`python`), `uv`, a console script, or a native binary from the environment's `bin`. Point editors and git hooks at those targets through bazel_env.

## Not hermetic

uv downloads the interpreter and the packages itself, not through Bazel's downloader. So `--repository_cache` and `--experimental_downloader_config` don't apply to them. Every download is still verified against a pinned hash.
