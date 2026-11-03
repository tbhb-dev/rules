# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Print the workspace members a uv.lock records, as JSON.

Usage: python lock_info.py UV_LOCK

Run by the tbhb_python repository rule with the interpreter uv installed.
Each member is {"name", "path", "kind"}: kind is "virtual" for a project
that is not built (a workspace root with `package = false`) and "editable"
for one that is installed from its source tree. A lock without a
`[manifest]` table records a single project: the package whose source is a
local virtual or editable path.
"""

import json
import sys
import tomllib
from pathlib import Path

KINDS = ("virtual", "editable")


class LockError(Exception):
    """The lock does not have the shape uv writes."""


def table(value: object) -> dict[str, object]:
    """Return value as a TOML table, or an empty one if it is not a table."""
    return value if isinstance(value, dict) else {}


def members(lock: dict[str, object]) -> list[dict[str, str]]:
    """Return the workspace members of a parsed uv.lock."""
    packages = lock.get("package", [])
    if not isinstance(packages, list):
        message = "`package` is not an array of tables"
        raise LockError(message)
    names = table(lock.get("manifest")).get("members")
    found: list[dict[str, str]] = []
    rows: list[object] = packages
    for value in rows:
        package = table(value)
        source = table(package.get("source"))
        name = str(package.get("name"))
        if isinstance(names, list) and name not in names:
            continue
        found.extend(
            {"name": name, "path": str(source[kind]), "kind": kind}
            for kind in KINDS
            if kind in source
        )
    if not found:
        message = "it records no local project"
        raise LockError(message)
    return found


def main(argv: list[str]) -> int:
    """Print the members of the lock named in argv as JSON."""
    if len(argv) != 1:
        print("usage: lock_info.py UV_LOCK", file=sys.stderr)
        return 2
    with Path(argv[0]).open("rb") as lock:
        data = tomllib.load(lock)
    try:
        print(json.dumps({"members": members(data)}))
    except LockError as error:
        print(f"{argv[0]}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
