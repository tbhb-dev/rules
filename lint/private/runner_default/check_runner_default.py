# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Require the caller-visibility runner default in reusable workflows."""

import os
import sys
from itertools import chain
from pathlib import Path

import yaml

# An explicit input wins. Otherwise a private caller reads the org variable
# and a public caller, which never receives it, gets the hosted label. An
# unset variable falls back to the hosted label too.
EXPRESSION = (
    "${{ inputs.runs-on || (github.event.repository.private "
    "&& vars.PRIVATE_RUNNER_LABEL || 'ubuntu-26.04') }}"
)


def main() -> int:
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    workflows = root / ".github/workflows"
    status = 0
    for path in sorted(chain(workflows.glob("*.yml"), workflows.glob("*.yaml"))):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        # PyYAML reads the bare key `on` as True.
        triggers = workflow.get("on", workflow.get(True))
        call = triggers.get("workflow_call") if isinstance(triggers, dict) else None
        inputs = (call or {}).get("inputs", {})
        reusable = "runs-on" in inputs
        problems = []
        if reusable and inputs["runs-on"].get("default"):
            problems.append("input 'runs-on' sets a default")
        for job_id, job in workflow["jobs"].items():
            runner = job.get("runs-on")
            if "uses" in job:
                continue
            if (
                reusable or "PRIVATE_RUNNER_LABEL" in str(runner)
            ) and runner != EXPRESSION:
                problems.append(f"job {job_id!r} does not use the runner default")
        for problem in problems:
            sys.stdout.write(f"{path.relative_to(root).as_posix()}: {problem}\n")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
