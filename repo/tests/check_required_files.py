# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Check that a consumer repository has the files its kind requires.

Usage: check_required_files.py MANIFEST SCHEMA REPO
MANIFEST is the baseline's manifest.toml, SCHEMA its repo.schema.json, and REPO
the consumer's root. The required paths are the repository's `[kind.<kind>]`
list plus the `[visibility.public]` or `[visibility.private]` list. A path that
ends in `/` must be a directory; any other path must be a file. Failures are
one line each. A `.tbhb-repo.toml` exception for C4 hides one missing path.
"""

import argparse
import json
import sys
import tomllib
from pathlib import Path

from jsonschema import Draft202012Validator

CHECK = "C4"


def is_present(repo: Path, path: str) -> bool:
    candidate = repo / path
    # A symlink that leaves the repository does not count as present.
    if not candidate.resolve().is_relative_to(repo.resolve()):
        return False
    return candidate.is_dir() if path.endswith("/") else candidate.is_file()


def missing_paths(repo: Path, required: list[str]) -> list[str]:
    return [path for path in dict.fromkeys(required) if not is_present(repo, path)]


def check(manifest: Path, schema: Path, repo: Path) -> list[str]:
    declaration_path = repo / ".tbhb-repo.toml"
    if not declaration_path.is_file():
        return [f"{declaration_path}: missing"]
    try:
        declaration = tomllib.loads(declaration_path.read_text())
    except tomllib.TOMLDecodeError as error:
        return [f"{declaration_path}: invalid TOML: {error}"]
    validator = Draft202012Validator(json.loads(schema.read_text()))
    problems = sorted(
        f"{declaration_path}: {error.json_path}: {error.message}"
        for error in validator.iter_errors(declaration)
    )
    if problems:
        return problems
    rules = tomllib.loads(manifest.read_text())
    visibility = "private" if declaration["private"] else "public"
    required = (
        rules["kind"][declaration["kind"]]["required"]
        + rules["visibility"][visibility]["required"]
    )
    missing = missing_paths(repo, required)
    exceptions = {
        entry["path"]: entry["reason"]
        for entry in declaration.get("exception", [])
        if entry["check"] == CHECK
    }
    errors = [
        f"{repo}: required {'directory' if path.endswith('/') else 'file'} "
        f"{path} is missing"
        for path in missing
        if path not in exceptions
    ]
    errors += [
        f"{declaration_path}: exception for {path} but it is not missing"
        for path in exceptions
        if path not in missing
    ]
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("schema", type=Path)
    parser.add_argument("repo", type=Path)
    args = parser.parse_args(argv)
    errors = check(args.manifest, args.schema, args.repo)
    sys.stdout.write("".join(f"{error}\n" for error in errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
