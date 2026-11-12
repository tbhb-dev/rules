# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Checks commit messages and added diff lines for private repository tokens."""

import argparse
import ast
import fnmatch
import os
import re
import subprocess  # nosec B404
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

TOKEN = re.compile(r"(?<![\w.-])[\w-]+(?:\.[\w-]+)*(?![\w-])", re.ASCII)
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def normalize(token: str) -> str:
    return token.lower().removesuffix(".git")


def configured_names(value: str) -> set[str]:
    return {
        normalize(name.strip()) for name in re.split(r"[,\n]", value) if name.strip()
    }


def is_private(token: str, names: set[str]) -> bool:
    name = normalize(token)
    return (name.endswith("-private") and not name.startswith("-")) or name in names


def problems(line: str, names: set[str]) -> Iterator[str]:
    seen: set[str] = set()
    for match in TOKEN.finditer(line):
        token = match.group()
        name = normalize(token)
        if is_private(token, names) and name not in seen:
            seen.add(name)
            yield (
                f"'{token}' names a private repository; describe it generically instead"
            )


def git(*args: str, check: bool = True) -> str:
    # Fixed Git subcommands use argument lists; range endpoints are verified.
    return subprocess.run(  # noqa: S603 # nosec B603, B607
        ["git", "-c", "core.quotePath=false", *args],  # noqa: S607
        check=check,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    ).stdout


def added_lines(diff: str) -> Iterator[tuple[str, int, str]]:
    path = ""
    number = 0
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            path, number = "", 0
        elif line.startswith("+++ ") and number == 0:
            raw = line[4:]
            path = (ast.literal_eval(raw) if raw.startswith('"') else raw)[2:]
        elif match := HUNK.match(line):
            number = int(match[1])
        elif number and line.startswith("+"):
            yield path, number, line[1:]
            number += 1
        elif number and line.startswith(" "):
            number += 1


def check_text(text: str, names: set[str], location: str) -> int:
    count = 0
    for line in text.splitlines():
        for problem in problems(line, names):
            print(f"private_names: FAIL: {location}: {problem}")
            count += 1
    return count


def committed_excludes() -> list[str]:
    path = (
        Path(git("rev-parse", "--show-toplevel").strip())
        / ".github/private-names-exclude.txt"
    )
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []
    patterns: list[str] = []
    reason = ""
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if line.startswith("#"):
            reason = line[1:].strip()
        elif line:
            if not reason:
                msg = (
                    f".github/private-names-exclude.txt:{number}: "
                    "exclusion glob requires a reason comment directly above it"
                )
                raise ValueError(msg)
            patterns.append(line)
            reason = ""
        else:
            reason = ""
    return patterns


def check_range(base: str, head: str, names: set[str], excludes: list[str]) -> int:
    # Resolve both endpoints first, so an invalid or option-like revision
    # cannot turn a bad range into a successful scan of no commits.
    base = git("rev-parse", "--verify", "--end-of-options", base + "^{commit}").strip()
    head = git("rev-parse", "--verify", "--end-of-options", head + "^{commit}").strip()
    commits = git("rev-list", "--reverse", f"{base}..{head}").splitlines()
    count = 0
    for sha in commits:
        count += check_text(
            git("log", "-1", "--format=%B", sha), names, f"{sha} message"
        )
        # Compare merges to their first parent too, including resolution
        # changes that a combined diff can omit.
        diff = git(
            "show",
            "--format=",
            "--unified=0",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--diff-merges=first-parent",
            sha,
        )
        for path, number, line in added_lines(diff):
            if not any(fnmatch.fnmatchcase(path, pattern) for pattern in excludes):
                count += check_text(line, names, f"{sha} {path}:{number}")
    if count:
        print(f"private_names: {count} problems in {len(commits)} commits checked")
    else:
        print(f"private_names: {len(commits)} commits checked")
    return int(count > 0)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--text", action="store_true", help="check stdin instead of commits"
    )
    parser.add_argument("revisions", nargs="*")
    args = parser.parse_args(argv)
    endpoints = 2
    if (args.text and args.revisions) or (
        not args.text and len(args.revisions) != endpoints
    ):
        parser.error("pass BASE HEAD, or --text")
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if workspace:
        os.chdir(workspace)
    names = configured_names(os.environ.get("PRIVATE_NAMES", ""))
    excludes = re.split(r"[,\n]", os.environ.get("PRIVATE_NAMES_EXCLUDE", ""))
    excludes = [pattern.strip() for pattern in excludes if pattern.strip()]
    try:
        origin = git("remote", "get-url", "origin", check=False).strip()
        if is_private(origin.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1], names):
            print("private_names: skipped private repository")
            return 0
        if args.text:
            count = check_text(sys.stdin.read(), names, "text")
            print(f"private_names: {count} problems in text checked")
            return int(count > 0)
        excludes.extend(committed_excludes())
        return check_range(args.revisions[0], args.revisions[1], names, excludes)
    except ValueError as error:
        print(f"private_names: FAIL: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError, OSError:
        print(
            "private_names: FAIL: git cannot read the repository or range",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
