# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Attach the module's base to local policy without changing source files."""

import sys
from pathlib import Path
from typing import Any

import tomlkit


def rule_ids(config: Path) -> set[str]:
    """Resolve the path extensions used by the wrapper's effective config."""
    policy = tomlkit.parse(config.read_text())
    extension: dict[str, Any] = dict(policy.get("extend", {}))
    inherited = rule_ids(Path(extension["path"])) if "path" in extension else set()
    inherited.difference_update(extension.get("disabledRules", []))
    rules: list[dict[str, Any]] = list(policy.get("rules", []))
    return inherited | {str(rule["id"]) for rule in rules}


def require_rules(config: Path) -> None:
    if not rule_ids(config):
        message = "effective gitleaks config has zero rules; refusing to scan"
        raise ValueError(message)


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
    require_rules(private if private.exists() else effective)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--check":
            require_rules(Path(sys.argv[2]))
        else:
            prepare(*(Path(arg) for arg in sys.argv[1:]))
    except (ValueError, OSError) as error:
        sys.exit(f"gitleaks_tool: FAIL: {error}")
