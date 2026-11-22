# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Attach the module's base to local policy without changing source files."""

import sys
import tomllib
from pathlib import Path
from typing import cast

import tomlkit

OWN_CONFIG_PATH = r"^\.gitleaks\.toml$"


def rule_ids(config: Path) -> set[str]:
    """Resolve the path extensions used by the wrapper's effective config."""
    policy = tomllib.loads(config.read_text())
    extension = policy.get("extend", {})
    inherited = rule_ids(Path(extension["path"])) if "path" in extension else set()
    inherited.difference_update(extension.get("disabledRules", []))
    return inherited | {rule["id"] for rule in policy.get("rules", [])}


def require_rules(config: Path) -> set[str]:
    """Return resolved rule IDs or fail closed when none remain."""
    rules = rule_ids(config)
    if not rules:
        message = "effective gitleaks config has zero rules; refusing to scan"
        raise ValueError(message)
    return rules


def add_own_config_allowlist(
    policy: tomlkit.TOMLDocument, target_rules: list[str]
) -> None:
    """Skip the root config only for custom rules defined in it."""
    allowlist = tomlkit.table()
    allowlist["description"] = "Own Gitleaks configuration"
    allowlist["targetRules"] = target_rules
    allowlist["paths"] = [tomlkit.string(OWN_CONFIG_PATH, literal=True)]
    allowlists = policy.get("allowlists")
    if allowlists is None:
        allowlists = tomlkit.aot()
        policy["allowlists"] = allowlists
    if "allowlist" in policy:
        singular = cast("dict[str, object]", policy.pop("allowlist"))
        allowlists.append(singular)
    allowlists.append(allowlist)


def prepare(base: Path, committed: Path, directory: Path) -> None:
    """Write effective policy and redirect the optional private extension."""
    policy = tomlkit.parse(committed.read_text())
    if "extend" in policy:
        message = "remove [extend] from the committed config; Bazel supplies the base"
        raise ValueError(message)
    local_rules = rule_ids(committed)
    policy["extend"] = {"path": base.as_posix()}
    effective = directory / "effective.toml"
    effective.write_text(tomlkit.dumps(policy))
    top_path, top_policy = effective, policy
    private = directory / "private.toml"
    if private.exists():
        private_policy = tomlkit.parse(private.read_text())
        if private_policy.get("extend") != {"path": ".gitleaks.toml"}:
            message = 'the private config must extend only path = ".gitleaks.toml"'
            raise ValueError(message)
        private_policy["extend"] = {"path": effective.as_posix()}
        private.write_text(tomlkit.dumps(private_policy))
        top_path, top_policy = private, private_policy
    active_rules = require_rules(top_path)
    # Gitleaks 8.30.1 applies [[allowlists]] targetRules only on the top-level
    # config, so attach the anchored own-config exception there for custom
    # rules defined in .gitleaks.toml.
    target_rules = sorted((local_rules - rule_ids(base)) & active_rules)
    if target_rules:
        add_own_config_allowlist(top_policy, target_rules)
        top_path.write_text(tomlkit.dumps(top_policy))


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--check":
            require_rules(Path(sys.argv[2]))
        else:
            prepare(*(Path(arg) for arg in sys.argv[1:]))
    except (ValueError, OSError) as error:
        sys.exit(f"gitleaks_tool: FAIL: {error}")
