# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Require the baseline's additional runner labels in actionlint configs."""

import os
import sys
from pathlib import Path

import yaml

CONFIG_PATH = ".github/actionlint.yaml"
# Keep the script's runfiles path when Bazel symlinks it to the source file.
BASELINE_PATH = (
    Path(__file__).absolute().parents[2] / "repo/baseline/files" / CONFIG_PATH
)


def _read_labels(path: Path) -> set[str]:
    with path.open(encoding="utf-8") as source:
        document: object = yaml.safe_load(source)
    match document:
        case {"self-hosted-runner": {"labels": list(labels)}}:
            return {label for label in labels if isinstance(label, str)}
        case _:
            return set()


def main() -> int:
    """Check the caller's actionlint config if it exists."""
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    config = root / CONFIG_PATH
    if not config.exists():
        return 0

    try:
        missing = sorted(_read_labels(BASELINE_PATH) - _read_labels(config))
    except yaml.YAMLError as error:
        sys.stderr.write(f"Invalid actionlint YAML.\n{error}\n")
        return 1
    except (OSError, UnicodeError) as error:
        sys.stderr.write(f"Could not read actionlint runner labels. {error}\n")
        return 1

    if missing:
        sys.stdout.write(
            f"{CONFIG_PATH} is missing runner labels: {', '.join(missing)}. "
            f"Copy them from the baseline's {CONFIG_PATH}.\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
