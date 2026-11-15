# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Require explicit timeouts on workflow jobs that run steps."""

import os
import sys
from itertools import chain
from pathlib import Path

import yaml


def main() -> int:
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    workflows = root / ".github/workflows"
    status = 0
    for path in sorted(chain(workflows.glob("*.yml"), workflows.glob("*.yaml"))):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_id, job in workflow["jobs"].items():
            if "uses" not in job and "timeout-minutes" not in job:
                sys.stdout.write(
                    f"{path.relative_to(root).as_posix()}: "
                    f"job {job_id!r} lacks timeout-minutes\n"
                )
                status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
