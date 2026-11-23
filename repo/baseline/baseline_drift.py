# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- The Bazel launcher also runs this module by path.

"""Check a consumer's bytes-mode baseline files."""

import argparse
import json
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import NotRequired, TypedDict, cast

from jsonschema import Draft202012Validator, ValidationError

BASELINE = Path(__file__).parent


class Entry(TypedDict):
    path: str
    source: str
    mode: str
    visibility: NotRequired[str]
    kinds: NotRequired[list[str]]
    template: NotRequired[bool]


class Manifest(TypedDict):
    file: list[Entry]
    kinds: list[str]


class ExceptionEntry(TypedDict):
    check: str
    path: str
    reason: str


class Declaration(TypedDict):
    kind: str
    private: bool
    exception: NotRequired[list[ExceptionEntry]]


class DeclarationError(ValueError):
    """The consumer declaration or an exception needs correction."""


@dataclass(frozen=True)
class Difference:
    path: str
    status: str


def load_toml(path: Path) -> dict[str, object]:
    with path.open("rb") as stream:
        return tomllib.load(stream)


def validator(path: Path) -> Draft202012Validator:
    return Draft202012Validator(json.loads(path.read_bytes()))


def load_declaration(repo: Path, baseline: Path) -> Declaration:
    schema = validator(baseline / "repo.schema.json")
    path = repo / ".tbhb-repo.toml"
    try:
        data = load_toml(path)
        schema.validate(data)
    except (FileNotFoundError, ValueError, ValidationError) as error:
        detail = error.message if isinstance(error, ValidationError) else str(error)
        msg = f"{path.name}: {detail}"
        raise DeclarationError(msg) from error
    return cast("Declaration", data)


def c2_exceptions(declaration: Declaration) -> dict[str, str]:
    exceptions: dict[str, str] = {}
    for entry in declaration.get("exception", []):
        if entry["check"] != "C2":
            continue
        path = entry["path"]
        if path in exceptions:
            msg = f".tbhb-repo.toml: duplicate C2 exception for {path}"
            raise DeclarationError(msg)
        exceptions[path] = entry["reason"]
    return exceptions


def selected_entries(manifest: Manifest, declaration: Declaration) -> list[Entry]:
    visibility = "private" if declaration["private"] else "public"
    return [
        entry
        for entry in manifest["file"]
        if entry["mode"] == "bytes"
        and entry.get("visibility", "all") in ("all", visibility)
        and declaration["kind"] in entry.get("kinds", manifest["kinds"])
    ]


def difference(repo: Path, baseline: Path, entry: Entry) -> Difference | None:
    path = entry["path"]
    if entry.get("template", False):
        sys.stdout.write(f"C2 note: skipped {path} (requires substitution)\n")
        return None

    expected = (baseline / entry["source"]).read_bytes()
    try:
        current = (repo / path).read_bytes()
    except FileNotFoundError:
        return Difference(path, "missing")
    if current == expected:
        return None
    return Difference(path, "differs")


def pending_changes(repo: Path, baseline: Path, manifest: Manifest) -> list[Difference]:
    declaration = load_declaration(repo, baseline)
    exceptions = c2_exceptions(declaration)
    changes = {
        diff.path: diff
        for entry in selected_entries(manifest, declaration)
        if (diff := difference(repo, baseline, entry)) is not None
    }
    stale = exceptions.keys() - changes.keys()
    if stale:
        msg = f".tbhb-repo.toml: stale C2 exceptions for {', '.join(sorted(stale))}"
        raise DeclarationError(msg)
    for path, reason in exceptions.items():
        sys.stdout.write(f"C2 exception for {path}: {reason}\n")
        del changes[path]
    return list(changes.values())


def main(argv: list[str] | None = None, *, baseline: Path = BASELINE) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(required=True)
    check = commands.add_parser("check")
    check.add_argument("repo", type=Path)
    check.add_argument("--mode", choices=["warn", "required"], required=True)
    args = parser.parse_args(argv)
    try:
        data = load_toml(baseline / "manifest.toml")
        validator(baseline / "manifest.schema.json").validate(data)
        manifest = cast("Manifest", data)
        repo: Path = args.repo.resolve()
        changes = pending_changes(repo, baseline, manifest)
    except DeclarationError as error:
        sys.stderr.write(f"C2 error: {error}\n")
        return 1
    except (OSError, ValueError, ValidationError) as error:
        sys.stderr.write(f"C2 error: {error}\n")
        return 2
    warns: bool = args.mode == "warn"
    for diff in changes:
        level = "warning" if warns else "error"
        sys.stdout.write(f"C2 {level}: {diff.path} {diff.status}\n")
    return 1 if changes and not warns else 0


if __name__ == "__main__":
    sys.exit(main())
