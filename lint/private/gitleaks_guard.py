# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Reject raw gitleaks binaries in consumer tool dictionaries."""

import os
import re
import subprocess
import sys
from pathlib import Path

RAW_MAPPING = re.compile(
    r"[\"']gitleaks[\"']\s*:\s*[\"']@tbhb_rules_gitleaks//:gitleaks[\"']"
)
OWN_PATHS = ("lint/private/", "lint/tests/", "pins/", "e2e/smoke/BUILD.bazel")


def main() -> int:
    tree = "--tree" in sys.argv[1:]
    root = Path("." if tree else os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    module = root / "MODULE.bazel"
    own_repo = module.exists() and re.search(
        r"module\(\s*name\s*=\s*[\"']tbhb_rules[\"']", module.read_text()
    )
    if tree:
        paths = [p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()]
    else:
        paths = subprocess.check_output(
            ["git", "ls-files", "-z"],  # noqa: S607
            cwd=root,
            text=True,
        ).split("\0")
    status = 0
    for name in sorted(paths):
        path = Path(name)
        if not name or not (
            path.name in {"BUILD", "BUILD.bazel"}
            or path.suffix == ".bzl"
            or "bazel_env" in path.name
        ):
            continue
        if own_repo and name.startswith(OWN_PATHS):
            continue
        source = "\n".join(
            line.split("#", 1)[0] for line in (root / path).read_text().splitlines()
        )
        for match in RAW_MAPPING.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            sys.stderr.write(
                f"{name}:{line}: gitleaks_guard: use @tbhb_rules//lint:gitleaks "
                "instead of the raw binary; it does not supply the shared ruleset\n"
            )
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
