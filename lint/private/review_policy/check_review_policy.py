# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Run the pinned `tbhbdev alpha review policy check` and report its verdict.

Usage: check_review_policy.py TBHBDEV_SRC PATH

TBHBDEV_SRC is the `src` directory of the tbhbdev source tree, put on the
import path. The check exits 0 when clean, 1 with findings and 2 when PATH or
the floor fails to load; this script exits 0 only for a clean run.
"""

import json
import os
import subprocess  # nosec B404
import sys
from typing import cast


def load(stdout: str) -> dict[str, object]:
    """The check's --json verdict, or an empty one when stdout holds none."""
    try:
        data = json.loads(stdout)
    except ValueError:
        return {}
    return cast("dict[str, object]", data) if isinstance(data, dict) else {}


def findings(verdict: dict[str, object]) -> list[str]:
    """One `PATH: ID: MESSAGE` line per finding of the verdict."""
    items = verdict.get("findings")
    if not isinstance(items, list):
        return []
    return [
        f"{item.get('path')}: {item.get('id')}: {item.get('message')}"
        for item in cast("list[dict[str, object]]", items)
        if isinstance(item, dict)
    ]


def report(code: int, stdout: str, stderr: str) -> list[str]:
    """What to print for an exit status that is not 0."""
    verdict = load(stdout)
    message = verdict.get("message")
    if code == 1 and (lines := findings(verdict)):
        return lines
    if code == 2 and isinstance(message, str):  # noqa: PLR2004 -- the check's own status
        return [message]
    return [f"exit status {code}", stdout.strip(), stderr.strip()]


def main(argv: list[str]) -> int:
    source, path = argv
    python_path = [source, *filter(None, [os.environ.get("PYTHONPATH")])]
    command = [sys.executable, "-m", "tbhbdev", "alpha", "review", "policy", "check"]
    result = subprocess.run(  # noqa: S603  # nosec B603
        [*command, path, "--json"],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "PYTHONPATH": os.pathsep.join(python_path)},
    )
    if result.returncode == 0:
        sys.stdout.write("review_policy: no findings\n")
        return 0
    lines = report(result.returncode, result.stdout, result.stderr)
    sys.stdout.write("\n".join(line for line in lines if line) + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
