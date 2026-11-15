# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Attach the module's base to local policy without changing source files."""

import sys
from pathlib import Path

import tomlkit


def prepare(base: Path, committed: Path, directory: Path) -> None:
    """Write effective policy and redirect the optional private extension."""
    policy = tomlkit.parse(committed.read_text())
    if "extend" in policy:
        message = "remove [extend] from the committed config; Bazel supplies the base"
        raise ValueError(message)
    policy["extend"] = {"path": base.as_posix()}
    effective = directory / "effective.toml"
    effective.write_text(tomlkit.dumps(policy))
    private = directory / "private.toml"
    if private.exists():
        policy = tomlkit.parse(private.read_text())
        if policy.get("extend") != {"path": ".gitleaks.toml"}:
            message = 'the private config must extend only path = ".gitleaks.toml"'
            raise ValueError(message)
        policy["extend"] = {"path": effective.as_posix()}
        private.write_text(tomlkit.dumps(policy))


if __name__ == "__main__":
    try:
        prepare(*(Path(arg) for arg in sys.argv[1:]))
    except (ValueError, OSError) as error:
        sys.exit(f"gitleaks_tool: FAIL: {error}")
