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


def members(lock: dict[str, object]) -> list[dict[str, str]]:
    """Return the workspace members of a parsed uv.lock."""
    packages = lock.get("package", [])
    if not isinstance(packages, list):
        raise SystemExit("uv.lock: `package` is not an array of tables")
    manifest = lock.get("manifest", {})
    names = manifest.get("members") if isinstance(manifest, dict) else None
    found = []
    for package in packages:
        source = package.get("source", {})
        for kind in ("virtual", "editable"):
            if kind in source and (names is None or package["name"] in names):
                found.append({"name": package["name"], "path": source[kind], "kind": kind})
    if not found:
        raise SystemExit("uv.lock records no local project")
    return found


def main(argv: list[str]) -> int:
    """Print the members of the lock named in argv as JSON."""
    if len(argv) != 1:
        sys.stderr.write("usage: lock_info.py UV_LOCK\n")
        return 2
    with Path(argv[0]).open("rb") as lock:
        print(json.dumps({"members": members(tomllib.load(lock))}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
