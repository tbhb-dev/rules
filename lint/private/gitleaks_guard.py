# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Reject raw gitleaks binaries in consumer tool dictionaries."""

import os
import re
import subprocess  # nosec B404
import sys
from pathlib import Path

RAW_MAPPING = re.compile(
    r"[\"']gitleaks[\"']\s*:\s*[\"']@tbhb_rules_gitleaks//:gitleaks[\"']"
)
OWN_PATHS = ("lint/private/", "lint/tests/", "pins/", "e2e/smoke/BUILD.bazel")


def is_own_repo(root: Path) -> bool:
    module = root / "MODULE.bazel"
    return bool(
        module.exists()
        and re.search(r"module\(\s*name\s*=\s*[\"']tbhb_rules[\"']", module.read_text())
    )


def candidate_paths(root: Path, *, tree: bool) -> list[str]:
    if tree:
        return [p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()]
    return subprocess.check_output(  # nosec B603, B607
        ["git", "ls-files", "-z"],  # noqa: S607
        cwd=root,
        text=True,
    ).split("\0")


def is_build_file(name: str) -> bool:
    path = Path(name)
    return bool(name) and (
        path.name in {"BUILD", "BUILD.bazel"}
        or path.suffix == ".bzl"
        or "bazel_env" in path.name
    )


def violations(root: Path, name: str) -> list[int]:
    source = "\n".join(
        line.split("#", 1)[0] for line in (root / name).read_text().splitlines()
    )
    return [
        source.count("\n", 0, match.start()) + 1
        for match in RAW_MAPPING.finditer(source)
    ]


def main() -> int:
    tree = "--tree" in sys.argv[1:]
    root = Path("." if tree else os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    own_repo = is_own_repo(root)
    status = 0
    for name in sorted(candidate_paths(root, tree=tree)):
        if not is_build_file(name) or (own_repo and name.startswith(OWN_PATHS)):
            continue
        for line in violations(root, name):
            sys.stderr.write(
                f"{name}:{line}: gitleaks_guard: use @tbhb_rules//lint:gitleaks "
                "instead of the raw binary; it does not supply the shared ruleset\n"
            )
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
