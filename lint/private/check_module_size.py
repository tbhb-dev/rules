# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Check physical source and test file lengths in the caller's Git worktree."""

import argparse
import json
import os
import subprocess  # nosec B404
import sys
import tomllib
from dataclasses import dataclass, field, fields
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from collections.abc import Iterable, Sequence


@dataclass(frozen=True)
class Settings:
    source_limit: int = 500
    test_limit: int = 1000
    source_globs: tuple[str, ...] = tuple(
        f"**/*.{extension}"
        for extension in (
            "py",
            "go",
            "ts",
            "tsx",
            "js",
            "rs",
            "swift",
            "kt",
            "java",
            "c",
            "h",
            "cc",
            "cpp",
            "sh",
        )
    )
    test_globs: tuple[str, ...] = (
        "**/test_*.py",
        "**/*_test.py",
        "**/*_test.go",
        "**/*.test.ts",
        "**/*.test.tsx",
        "**/*.spec.ts",
        "**/*Tests.swift",
        "**/*Test.swift",
        "**/tests/**",
        "**/__tests__/**",
    )
    ignore_globs: tuple[str, ...] = (
        "**/node_modules/**",
        "**/vendor/**",
        "**/.bazel*/**",
        "**/*.pb.go",
        "**/*_pb2.py",
        "**/generated/**",
    )
    baseline: dict[str, int] = field(default_factory=dict)


def _line_limit(value: object, key: str) -> int:
    if type(value) is not int or value < 0:
        msg = f"{key} must be a nonnegative integer"
        raise ValueError(msg)
    return value


def _globs(value: object, key: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(
        isinstance(glob, str) and glob for glob in value
    ):
        msg = f"{key} must be an array of nonempty glob strings"
        raise ValueError(msg)
    return tuple(cast("list[str]", value))


def read_settings(path: Path) -> Settings:
    with path.open("rb") as config:
        entries = tomllib.load(config)
    unknown = entries.keys() - {item.name for item in fields(Settings)}
    if unknown:
        msg = f"unknown configuration keys: {', '.join(sorted(unknown))}"
        raise ValueError(msg)
    baseline = entries.get("baseline", {})
    if not isinstance(baseline, dict):
        msg = "baseline must be a TOML table of paths and line counts"
        raise TypeError(msg)
    for key in entries.keys() & {"source_limit", "test_limit"}:
        entries[key] = _line_limit(entries[key], key)
    for key in entries.keys() & {"source_globs", "test_globs", "ignore_globs"}:
        entries[key] = _globs(entries[key], key)
    entries["baseline"] = {
        name: _line_limit(count, f"baseline entry {name!r}")
        for name, count in baseline.items()
    }
    return Settings(**entries)


def measure(
    root: Path, paths: Iterable[str], settings: Settings
) -> dict[str, tuple[int, int]]:
    """Return each selected path's physical line count and applicable limit."""
    files = {}
    for name in paths:
        path = PurePosixPath(name)
        if not any(map(path.full_match, settings.source_globs)) or any(
            map(path.full_match, settings.ignore_globs)
        ):
            continue
        source = root / path
        if source.is_file(follow_symlinks=False):
            limit = (
                settings.test_limit
                if any(map(path.full_match, settings.test_globs))
                else settings.source_limit
            )
            with source.open("rb") as lines:
                files[name] = (sum(1 for _ in lines), limit)
    return files


def violations(
    files: dict[str, tuple[int, int]], baseline: dict[str, int]
) -> list[str]:
    messages = []
    for path, (count, limit) in sorted(files.items()):
        allowed = baseline.get(path)
        prefix = f"{path}: {count} lines"
        if allowed is None:
            if count > limit:
                messages.append(
                    f"{prefix}, over limit {limit}. Split or shorten the file."
                )
        elif count <= limit:
            messages.append(
                f"{prefix}, within limit {limit}. Remove baseline entry ({allowed})."
            )
        elif count > allowed:
            messages.append(
                f"{prefix}, over baseline {allowed}. Split or shorten the file."
            )
        elif count < allowed:
            messages.append(
                f"{prefix}, below baseline {allowed}. Lower the entry to {count}."
            )
    messages.extend(
        f"{path}: no counted file for baseline {baseline[path]}. Remove the entry."
        for path in sorted(baseline.keys() - files.keys())
    )
    return messages


def baseline_toml(files: dict[str, tuple[int, int]]) -> str:
    lines = ["[baseline]"]
    for path, (count, limit) in sorted(files.items()):
        if count > limit:
            key = json.dumps(path, ensure_ascii=False).replace("\x7f", r"\u007f")
            lines.append(f"{key} = {count}")
    return "\n".join(lines) + "\n"


def _tracked_paths(root: Path) -> list[str]:
    paths = subprocess.check_output(  # nosec B603, B607
        ["git", "ls-files", "--cached", "--deduplicate", "-z"],  # noqa: S607
        cwd=root,
    )
    return paths.decode().split("\0")[:-1]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="default: .github/module-size.toml")
    parser.add_argument(
        "--write-baseline", action="store_true", help="print the baseline table"
    )
    args = parser.parse_args(argv)
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    config = root / (args.config or ".github/module-size.toml")
    try:
        settings = (
            read_settings(config) if args.config or config.exists() else Settings()
        )
        files = measure(root, _tracked_paths(root), settings)
    except (OSError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        sys.stderr.write(f"module_size: {config}: {error}\n")
        return 2
    if args.write_baseline:
        sys.stdout.write(baseline_toml(files))
        return 0
    messages = violations(files, settings.baseline)
    for message in messages:
        sys.stderr.write(f"{message}\n")
    return int(bool(messages))


if __name__ == "__main__":
    sys.exit(main())
