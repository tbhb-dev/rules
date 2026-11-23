# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Require a trailing newline in each changed text file in a Git range."""

import argparse
import os
import re
import subprocess  # nosec B404
import sys
from pathlib import Path

# The top-level exclude and the end-of-file-fixer exclude in .pre-commit-config.yaml.
HOOK_EXCLUDE = re.compile(
    rb"""(?x)^(
        \.vale/(Google|write-good|proselint|ai-tells.*)/
        |\.bazel-.*/|bazel-.*/|tmp/|\.worktrees/
        |(.*/)?(mutants|testdata)/
        |.*\.d2\.(svg|png|sha256)$
        |(.*/)?structurizr-[^/]*\.(svg|png)$
        |(.*/)?workspace\.json$
        |(.*/)?worker-configuration\.d\.ts$
        |lint/gitleaks/(base|upstream)\.toml$
    )"""
)
# The remaining path expression in the Bedrock allowlist in .gitleaks.toml.
BEDROCK_EXCLUDE = re.compile(rb"(^|/)\.gitleaks-rules\.toml$")
TEXT_SAMPLE_SIZE = 8192


def _git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(  # noqa: S603  # nosec B603, B607
        ["git", *args],  # noqa: S607
        cwd=root,
    )


def check(root: Path, base: str, head: str) -> int:
    # Treat a rename as an addition at its new path. Raw output gives us
    # both the mode and the object ID of the committed file.
    records = _git(
        root,
        "diff",
        "--raw",
        "-z",
        "--no-abbrev",
        "--no-ext-diff",
        "--no-renames",
        "--diff-filter=AMT",
        "--end-of-options",
        base,
        head,
        "--",
    ).split(b"\0")[:-1]
    status = 0
    for metadata, path in zip(records[0::2], records[1::2], strict=True):
        _, mode, _, object_id, _ = metadata.split()
        if (
            HOOK_EXCLUDE.match(path)
            or BEDROCK_EXCLUDE.search(path)
            or not mode.startswith(b"100")
        ):
            continue
        blob = _git(root, "cat-file", "blob", object_id.decode("ascii"))
        if blob and b"\0" not in blob[:TEXT_SAMPLE_SIZE] and not blob.endswith(b"\n"):
            sys.stderr.write(f"{os.fsdecode(path)!r}: missing trailing newline\n")
            status = 1
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args()
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    try:
        return check(root, args.base, args.head)
    except subprocess.CalledProcessError:
        return 2


if __name__ == "__main__":
    sys.exit(main())
