# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Check that a consumer repository has the files its kind requires.

Usage: check_required_files.py MANIFEST SCHEMA REPO
MANIFEST is the baseline's manifest.toml, SCHEMA its repo.schema.json, and REPO
the consumer's root. Exit 1 reports content problems; exit 2 reports unreadable
inputs or an unusable schema. A bad .tbhb-repo.toml exits 1 only after the manifest
and schema are readable. The required paths combine `[kind.<kind>]` and
`[visibility.public]` or `[visibility.private]`. A trailing slash requires a
directory; other paths require files. Missing paths get one line each. Manifest
validation stops at the first bad table, entry or path. A .tbhb-repo.toml C4
exception hides one missing path.
"""

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import TypeIs

from jsonschema import Draft202012Validator, SchemaError
from referencing import Registry
from referencing.exceptions import Unresolvable

CHECK = "C4"
# Status 1 means the check found problems; 2 means an input is unusable.
UNUSABLE = 2
# The path pattern in manifest.schema.json rejects a leading slash or a
# `..` segment.
INVALID_PATH = re.compile(r"^/|^[A-Za-z]:|(?:^|/)\.\.(?:/|$)|[\n\r\\\x00]")


def is_present(repo: Path, path: str) -> bool:
    candidate = repo / path
    # A symlink that leaves the repository does not count as present.
    if not candidate.resolve().is_relative_to(repo.resolve()):
        return False
    return candidate.is_dir() if path.endswith("/") else candidate.is_file()


def missing_paths(repo: Path, required: list[str]) -> list[str]:
    return [path for path in dict.fromkeys(required) if not is_present(repo, path)]


def c4_exception_paths(entries: list[dict[str, object]]) -> set[str] | None:
    exceptions = set()
    for entry in entries:
        if entry.get("check") != CHECK:
            continue
        path = entry.get("path")
        reason = entry.get("reason")
        if (
            not isinstance(path, str)
            or not path
            or not isinstance(reason, str)
            or not reason.strip()
        ):
            return None
        exceptions.add(path)
    return exceptions


def check(manifest: Path, schema: Path, repo: Path) -> list[str]:
    # Read both baseline inputs before judging any declaration or manifest content.
    schema_text = schema.read_bytes().decode()
    manifest_text = manifest.read_bytes().decode()
    try:
        schema_data = json.loads(schema_text)
    except json.JSONDecodeError as error:
        msg = f"invalid JSON: {error}"
        raise SchemaError(msg) from error
    Draft202012Validator.check_schema(schema_data)
    validate_schema_contract(schema_data)
    validator = Draft202012Validator(schema_data, registry=Registry())
    try:
        rules = tomllib.loads(manifest_text)
    except tomllib.TOMLDecodeError as error:
        return [f"{manifest}: invalid TOML: {error}"]
    declaration_path = repo / ".tbhb-repo.toml"
    if not declaration_path.is_file():
        return [f"{declaration_path}: missing"]
    try:
        declaration = tomllib.loads(declaration_path.read_bytes().decode())
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
        return [f"{declaration_path}: invalid TOML: {error}"]
    try:
        problems = sorted(
            f"{declaration_path}: {error.json_path}: {error.message}"
            for error in validator.iter_errors(declaration)
        )
    except Unresolvable as error:
        raise SchemaError(str(error)) from error
    if problems:
        return problems
    return check_rules(
        rules,
        manifest,
        repo,
        declaration["kind"],
        "private" if declaration["private"] else "public",
        declaration.get("exception", []),
    )


def check_manifest(
    manifest: Path,
    repo: Path,
    kind: str,
    visibility: str,
    entries: list[dict[str, object]],
) -> list[str]:
    try:
        rules = tomllib.loads(manifest.read_bytes().decode())
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
        return [f"{manifest}: invalid TOML: {error}"]
    return check_rules(rules, manifest, repo, kind, visibility, entries)


def validate_schema_contract(data: object) -> None:
    """Require the declaration fields used to select manifest entries."""
    if not is_table(data) or data.get("type") != "object":
        msg = "schema must define an object declaration"
        raise SchemaError(msg)
    required = data.get("required")
    properties = data.get("properties")
    if (
        not is_string_list(required)
        or not {"kind", "private"}.issubset(required)
        or not is_table(properties)
    ):
        msg = "schema must require and define kind and private"
        raise SchemaError(msg)
    kind = properties.get("kind")
    private = properties.get("private")
    if not is_table(kind) or not is_table(private):
        msg = "schema must define kind and private"
        raise SchemaError(msg)
    if (
        not (
            kind.get("type") == "string"
            or (is_string_list(kind.get("enum")) and kind["enum"])
        )
        or private.get("type") != "boolean"
    ):
        msg = "schema must constrain kind to strings and private to booleans"
        raise SchemaError(msg)

    validate_exception_schema(properties.get("exception"))


def validate_exception_schema(exception: object) -> None:
    """Require exceptions to be an array of objects before reading entries."""
    message = "schema must define exception as an array of objects"
    if not is_table(exception) or exception.get("type") != "array":
        raise SchemaError(message)
    items = exception.get("items")
    if not is_table(items) or items.get("type") != "object":
        raise SchemaError(message)


def check_rules(  # noqa: PLR0913, PLR0917 -- Manifest selection and diagnostic context.
    rules: dict[str, object],
    manifest: Path,
    repo: Path,
    kind: str,
    visibility: str,
    entries: list[dict[str, object]],
) -> list[str]:
    declaration_path = repo / ".tbhb-repo.toml"
    required: list[str] = []
    for table, name in (("kind", kind), ("visibility", visibility)):
        names: object = rules.get(table)
        if not is_table(names):
            return [f"{manifest}: {table} must be a table"]
        if name not in names:
            return [
                f'{declaration_path}: {table} "{name}" has no entry in the manifest'
            ]
        paths = required_list(names[name])
        if isinstance(paths, str):
            return [f'{manifest}: {table} "{name}" {paths}']
        required += paths
    return check_paths(repo, required, entries)


def required_list(entry: object) -> list[str] | str:
    """Return a manifest entry's required paths, or what is wrong with the entry."""
    if not is_table(entry):
        return "must be a table"
    paths: object = entry.get("required")
    if not is_string_list(paths):
        return "needs a required list of strings"
    for path in paths:
        if path in ("", ".", "./") or INVALID_PATH.search(path):
            return f"required path {path!r} must be a safe relative path"
    return paths


def is_table(value: object) -> TypeIs[dict[str, object]]:
    return isinstance(value, dict)


def is_string_list(value: object) -> TypeIs[list[str]]:
    if not isinstance(value, list):
        return False
    items: list[object] = value
    return all(isinstance(item, str) for item in items)


def check_paths(
    repo: Path, required: list[str], entries: list[dict[str, object]]
) -> list[str]:
    declaration_path = repo / ".tbhb-repo.toml"
    missing = missing_paths(repo, required)
    exceptions = c4_exception_paths(entries)
    if exceptions is None:
        return [f"{declaration_path}: C4 exception needs a path and a reason"]
    errors = [
        f"{repo}: required {'directory' if path.endswith('/') else 'file'} "
        f"{path} is missing"
        for path in missing
        if path not in exceptions
    ]
    errors += [
        f"{declaration_path}: exception for {path} but it is not missing"
        for path in sorted(exceptions)
        if path not in missing
    ]
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("schema", type=Path)
    parser.add_argument("repo", type=Path)
    args = parser.parse_args(argv)
    try:
        errors = check(args.manifest, args.schema, args.repo)
    except UnicodeDecodeError:
        sys.stdout.write("manifest or schema: cannot read UTF-8\n")
        return UNUSABLE
    except OSError as error:
        prefix = f"{error.filename}: " if error.filename else ""
        sys.stdout.write(f"{prefix}cannot read: {error.strerror}\n")
        return UNUSABLE
    except SchemaError as error:
        sys.stdout.write(
            f"{args.schema}: invalid schema: {error.message.splitlines()[0]}\n"
        )
        return UNUSABLE
    sys.stdout.write("".join(f"{error}\n" for error in errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
