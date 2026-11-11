#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Regenerate the module-provided Gitleaks base, or check it offline."""

import argparse
import hashlib
import json
import re
import subprocess
import tomllib
import urllib.request
from pathlib import Path

BASE = "lint/gitleaks/base.toml"


def fail(message: str) -> None:
    """Stop regeneration with a diagnostic."""
    raise ValueError(message)


def tracked_configs(root: Path) -> list[Path]:
    """Include new configs too, so a newly added module cannot escape the check."""
    paths = (
        subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=root,
        )
        .decode()
        .split("\0")
    )
    return sorted({root / p for p in paths if Path(p).name == ".gitleaks.toml"})


def generate(source: str, version: str, license_text: str) -> str:
    """Remove only the top-level allowlist, keeping every rule byte for byte."""
    start = source.index("# TODO: change to [[allowlists]]")
    end = source.index("[[rules]]")
    result = source[:start] + source[end:]
    original = tomllib.loads(source)
    parsed = tomllib.loads(result)
    if parsed.get("allowlist") or parsed.get("allowlists"):
        fail("generated base still has a global allowlist")
    if original["rules"] != parsed["rules"]:
        fail("generation changed default rules")
    return (
        "# SPDX-" + "License-Identifier: MIT\n"
        "# Copyright (c) 2019 Zachary Rice\n"
        f"# Generated from Gitleaks v{version} by lint/gitleaks/update.py.\n"
        "# Do not edit.\n#\n"
        + "".join(
            "# " + line + "\n" if line else "#\n" for line in license_text.splitlines()
        )
        + "\n"
        + result
    )


def main() -> None:
    """Read the pin once, regenerate the base, and fail closed on drift."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[2]
    )
    parser.add_argument(
        "--check", action="store_true", help="check offline without writing"
    )
    args = parser.parse_args()
    root = args.root.resolve()
    if root.is_file():
        root = root.parent
    vendor = root / "lint/gitleaks"
    versions = set(
        re.findall(
            r"gitleaks/releases/download/v([^/]+)/",
            (root / "pins/extensions.bzl").read_text(),
        )
    )
    if len(versions) != 1:
        fail(f"Gitleaks platform pins disagree: {versions}")
    version = versions.pop()
    metadata_path = vendor / "upstream.json"
    source_path = vendor / "upstream.toml"
    if not args.check:
        url = f"https://raw.githubusercontent.com/gitleaks/gitleaks/v{version}/config/gitleaks.toml"
        with urllib.request.urlopen(url, timeout=60) as response:
            source_path.write_bytes(response.read())
        metadata_path.write_text(
            json.dumps(
                {
                    "version": version,
                    "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                },
                indent=2,
            )
            + "\n"
        )
    metadata = json.loads(metadata_path.read_text())
    if metadata["version"] != version:
        fail("Gitleaks pin changed; run python3 lint/gitleaks/update.py")
    if hashlib.sha256(source_path.read_bytes()).hexdigest() != metadata["sha256"]:
        fail("vendored upstream config checksum differs")
    expected = generate(
        source_path.read_text(), version, (root / "LICENSES/MIT.txt").read_text()
    )
    configs = tracked_configs(root)
    if not configs:
        fail("no committed Gitleaks configs found")
    for config in configs:
        policy = tomllib.loads(config.read_text())
        if "extend" in policy:
            fail(
                f"{config.relative_to(root)} must contain only local policy, "
                "without extend"
            )
        if config.with_name(".gitleaks-rules.toml").exists():
            fail(f"{config.relative_to(root)} has an obsolete base copy")
    base = root / BASE
    if args.check:
        if base.read_text() != expected:
            fail(f"{BASE} is stale; regenerate it")
    else:
        base.write_text(expected)
    print(
        f"PASS: {len(configs)} configs keep all "
        f"{len(tomllib.loads(expected)['rules'])} gitleaks v{version} rules "
        "without its global allowlist"
    )


if __name__ == "__main__":
    main()
