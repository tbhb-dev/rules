# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
"""Check decision record filenames and unique numbers.

Usage: check_decisions.py [--directory DIR] [ROOT]

ROOT defaults to the current directory and DIR to docs/decisions, relative
to ROOT. Only immediate children are checked; file contents are never read.
Each failure is printed as `path: problem` before the script exits 1.
"""

import argparse
import re
import sys
from pathlib import Path

DIRECTORY = "docs/decisions"
DIRECTORY_HELP = "the decision records directory, under ROOT"
EXEMPT = frozenset({"index.md", "AGENTS.md", "CLAUDE.md"})
FILENAME = re.compile(r"(?P<number>\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md")


def check(root: Path, directory: str = DIRECTORY) -> list[str]:
    """Check the immediate children of ROOT/directory, if it exists."""
    folder = root / directory
    if not folder.exists():
        return []
    if not folder.is_dir():
        return [f"{directory}: not a directory"]
    errors: list[str] = []
    numbers: dict[str, str] = {}
    for path in sorted(folder.iterdir()):
        rel = path.relative_to(root).as_posix()
        if not path.is_file() or path.suffix != ".md":
            errors.append(f"{rel}: expected a Markdown file")
            continue
        if path.name in EXEMPT:
            continue
        match = FILENAME.fullmatch(path.name)
        if match is None:
            errors.append(f"{rel}: expected NNNN-<slug>.md")
            continue
        number = match["number"]
        if number in numbers:
            errors.append(f"{rel}: duplicate number {number} with {numbers[number]}")
        else:
            numbers[number] = rel
    return errors


def main(argv: list[str] | None = None) -> int:
    """Check ROOT and report every error."""
    parser = argparse.ArgumentParser(description="Check decision record filenames.")
    parser.add_argument("--directory", default=DIRECTORY, help=DIRECTORY_HELP)
    parser.add_argument("root", nargs="?", type=Path, default=Path())
    args = parser.parse_args(argv)
    errors = check(args.root, args.directory)
    for error in errors:
        print(error)
    if errors:
        return 1
    print("OK: decision record filenames and numbers conform")
    return 0


if __name__ == "__main__":
    sys.exit(main())
