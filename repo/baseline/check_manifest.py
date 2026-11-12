# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001  # pytest imports this repository-relative namespace.

"""Validate the baseline's manifest and references without checking consumers."""

import itertools
import json
import re
import tomllib
from typing import TYPE_CHECKING, cast

import yaml
from jsonschema import Draft202012Validator

if TYPE_CHECKING:
    from pathlib import Path


def read_keys(source: Path) -> dict[str, object]:
    loaders = {".toml": tomllib.loads, ".json": json.loads}
    return cast(
        "dict[str, object]",
        loaders.get(
            source.with_suffix("").suffix
            if source.suffix == ".baseline"
            else source.suffix,
            yaml.safe_load,
        )(source.read_text()),
    )


def check_keys(source: Path, keys: list[str]) -> None:
    for key in keys:
        value: object = read_keys(source)
        for segment in key.split("."):
            value = cast("dict[str, object]", value)[segment]


def check_template(content: str, placeholders: set[str], source: str) -> None:
    # GitHub expressions belong to Actions, not the writer. Only the
    # dollar-prefixed form is exempt; every other brace pair is ours.
    tokens = re.findall(r"(?<!\$){{(.*?)}}", content, flags=re.DOTALL)
    if set(tokens) - placeholders:
        msg = f"Undeclared placeholders in {source}"
        raise ValueError(msg)


def check_manifest(root: Path) -> None:
    """Raise for an invalid manifest, missing reference, or ambiguous destination."""
    manifest = tomllib.loads((root / "manifest.toml").read_text())
    schema = json.loads((root / "manifest.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(manifest)
    kinds = set(manifest["kinds"])
    unknown = set(manifest["kind"]) - kinds
    if unknown:
        msg = f"Unknown kind tables: {sorted(unknown)}"
        raise ValueError(msg)
    seen = set()
    for entry in manifest["file"]:
        source = root / entry["source"]
        content = source.read_text()
        selected = set(entry.get("kinds", kinds))
        if selected - kinds:
            msg = f"Unknown entry kinds: {sorted(selected - kinds)}"
            raise ValueError(msg)
        if entry["mode"] == "keys":
            check_keys(source, entry["keys"])
        if entry.get("template", False):
            check_template(content, set(manifest["placeholders"]), entry["source"])
        visibility = entry.get("visibility", "all")
        visibilities = ["public", "private"] if visibility == "all" else [visibility]
        for pair in itertools.product(visibilities, selected):
            destination = (entry["path"], *pair)
            if destination in seen:
                msg = f"Repeated destination: {destination}"
                raise ValueError(msg)
            seen.add(destination)
