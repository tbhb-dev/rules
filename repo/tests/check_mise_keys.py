# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Compare the table and key names of a mise.toml with the baseline copy.

Usage: check_mise_keys.py BASELINE MISE
Only names count, never values, because tool versions differ. Failures are
one line per key that only one side has. EXCEPTIONS lists the real current
differences, each by key path or table prefix.
"""

import argparse
import sys
import tomllib
from pathlib import Path

# Key path (or table prefix) to the reason this repository differs.
EXCEPTIONS = {
    "settings.idiomatic_version_file_enable_tools": "uv owns the Python interpreters",
    "settings.lockfile_platforms": "this repository does not set it yet",
    "env.UV_PYTHON_PREFERENCE": "uv provisions the interpreter",
    "tools.prek": "git hooks run from the Bazel-pinned shims",
    "tools.uv": "this repository pins uv",
    "tasks": "this repository defines tasks",
}


def key_paths(table: dict[str, object], prefix: str = "") -> set[str]:
    paths: set[str] = set()
    for name, value in table.items():
        path = prefix + name
        paths.add(path)
        if isinstance(value, dict):
            paths |= key_paths(value, path + ".")
    return paths


def is_excepted(path: str) -> bool:
    return any(path == known or path.startswith(known + ".") for known in EXCEPTIONS)


def check(baseline: Path, mise: Path) -> list[str]:
    base = key_paths(tomllib.loads(baseline.read_text()))
    repo = key_paths(tomllib.loads(mise.read_text()))
    errors = [
        f"{mise}: {path} is not in the baseline {baseline}"
        for path in sorted(repo - base)
        if not is_excepted(path)
    ]
    errors += [
        f"{mise}: {path} is in the baseline {baseline} but missing here"
        for path in sorted(base - repo)
        if not is_excepted(path)
    ]
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("mise", type=Path)
    args = parser.parse_args(argv)
    errors = check(args.baseline, args.mise)
    for error in errors:
        sys.stdout.write(error + "\n")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
