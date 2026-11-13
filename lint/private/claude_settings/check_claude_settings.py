# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Check repository Claude permissions and MCP servers.

Usage: check_claude_settings.py SETTINGS MCP
Failures are one line per problem, starting with the supplied file path.
"""

import argparse
import json
import sys
from pathlib import Path


def object_value(
    value: object, path: Path, key: str, errors: list[str]
) -> dict[str, object]:
    if isinstance(value, dict):
        result: dict[str, object] = value
        return result
    errors.append(f"{path}: {key} must be an object (missing or wrongly typed)")
    return {}


def read_object(path: Path, errors: list[str]) -> dict[str, object]:
    try:
        value: object = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        errors.append(f"{path}: cannot read JSON: {str(error)!r}")
        return {}
    return object_value(value, path, "JSON root", errors)


def string_list(value: object, path: Path, key: str, errors: list[str]) -> list[str]:
    if not isinstance(value, list):
        errors.append(
            f"{path}: {key} must be a list of strings (missing or wrongly typed)"
        )
        return []
    values: list[object] = value
    result: list[str] = []
    for index, item in enumerate(values):
        if isinstance(item, str):
            result.append(item)
        else:
            errors.append(f"{path}: {key}[{index}] must be a string")
    return result


def check_servers(
    settings: Path, enabled: list[str], allowed: list[str], servers: dict[str, object]
) -> list[str]:
    errors: list[str] = []
    for server in enabled:
        if "mcp__" + server not in allowed:
            errors.append(
                f"{settings}: permissions.allow missing {'mcp__' + server!r} "
                "for enabled server"
            )
        if server not in servers:
            errors.append(
                f"{settings}: enabledMcpjsonServers server {server!r} "
                "undefined in mcpServers"
            )
    for entry in allowed:
        if not entry.startswith("mcp__"):
            continue
        server = entry.removeprefix("mcp__")
        if not server or "__" in server:
            errors.append(
                f"{settings}: permissions.allow entry {entry!r} "
                "must be mcp__<server> with no tool suffix"
            )
        elif server not in servers:
            errors.append(
                f"{settings}: permissions.allow server {server!r} "
                "undefined in mcpServers"
            )
    return errors


def check(settings: Path, mcp: Path) -> list[str]:
    errors: list[str] = []
    config = read_object(settings, errors)
    servers = object_value(
        read_object(mcp, errors).get("mcpServers"), mcp, "mcpServers", errors
    )
    permissions = object_value(
        config.get("permissions"), settings, "permissions", errors
    )
    denied = string_list(permissions.get("deny"), settings, "permissions.deny", errors)
    allowed = string_list(
        permissions.get("allow"), settings, "permissions.allow", errors
    )
    enabled = string_list(
        config.get("enabledMcpjsonServers"), settings, "enabledMcpjsonServers", errors
    )
    for operation in ("create", "edit", "merge"):
        entry = f"Bash(gh pr {operation}:*)"
        if entry not in denied:
            errors.append(f"{settings}: permissions.deny missing {entry!r}")
    return errors + check_servers(settings, enabled, allowed, servers)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=Path)
    parser.add_argument("mcp", type=Path)
    args = parser.parse_args(argv)
    errors = check(args.settings, args.mcp)
    for error in errors:
        sys.stdout.write(error + "\n")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
