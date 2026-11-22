# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Require the caller-visibility runner default in reusable workflows."""

import os
import sys
from pathlib import Path

import yaml

# An explicit input wins. Otherwise a private caller reads the org variable
# and a public caller, which never receives it, gets the hosted label. An
# unset variable falls back to the hosted label too.
EXPRESSION = (
    "${{ inputs.runs-on || (github.event.repository.private "
    "&& vars.PRIVATE_RUNNER_LABEL || 'ubuntu-26.04') }}"
)


# PyYAML reads the bare key `on` as True.
BARE_ON = True


def _get(node: object, key: object) -> object:
    return node.get(key) if isinstance(node, dict) else None


def _items(node: object) -> list[tuple[object, object]]:
    return list(node.items()) if isinstance(node, dict) else []


def _problems(workflow: object) -> list[str]:
    triggers = _get(workflow, "on") or _get(workflow, BARE_ON)
    inputs = _get(_get(triggers, "workflow_call"), "inputs")
    reusable = _get(inputs, "runs-on") is not None
    found = []
    if _get(_get(inputs, "runs-on"), "default"):
        found.append("input 'runs-on' sets a default")
    for job_id, job in _items(_get(workflow, "jobs")):
        runner = _get(job, "runs-on")
        if _get(job, "uses") is not None:
            continue
        if (reusable or "PRIVATE_RUNNER_LABEL" in str(runner)) and runner != EXPRESSION:
            found.append(f"job {job_id!r} does not use the runner default")
    return found


def main() -> int:
    base = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    files = sorted((base / ".github/workflows").glob("*.y*ml"))
    status = 0
    for file in files:
        text = file.read_text(encoding="utf-8")
        for problem in _problems(yaml.safe_load(text)):
            sys.stdout.write(f"{file.relative_to(base).as_posix()}: {problem}\n")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
