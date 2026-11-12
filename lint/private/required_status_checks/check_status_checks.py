# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Check required status contexts and the CI conclusion job's dependencies.

Usage: check_status_checks.py RULESET WORKFLOW
Each problem is printed on one line as `path: problem`; failures exit 1.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import NotRequired, TypedDict, cast

import yaml

# Rules decision: these jobs need not gate a pull request. Keys are job ids,
# never display names. Every exemption must still exist in the workflow.
EXEMPT_JOBS = {
    "cache-warm": "Runs only on pushes to main, never on a pull request.",
}


class Parameters(TypedDict, total=False):
    required_status_checks: list[dict[str, str]]


class Rule(TypedDict):
    type: str
    parameters: NotRequired[Parameters]


class Ruleset(TypedDict, total=False):
    rules: list[Rule]


class Job(TypedDict, total=False):
    name: str
    needs: list[str] | str


class Workflow(TypedDict, total=False):
    jobs: dict[str, Job]


def check_context(context: str, jobs: dict[str, Job], ruleset_path: Path) -> list[str]:
    """Require one context to match only the conclusion job."""
    matches = [
        job_id for job_id, job in jobs.items() if job.get("name", job_id) == context
    ]
    if not matches:
        return [
            (
                f"{ruleset_path.as_posix()}: required context {context!r} "
                "has no matching CI job"
            )
        ]
    return [
        f"{ruleset_path.as_posix()}: required context {context!r} "
        f"matches job {job_id!r}, expected 'conclusion'"
        for job_id in matches
        if job_id != "conclusion"
    ]


def check_rule_contexts(
    rule: Rule, jobs: dict[str, Job], ruleset_path: Path
) -> list[str]:
    """Require a nonempty status list and check its contexts in order."""
    parameters = rule.get("parameters", {})
    required_status_checks = parameters.get("required_status_checks", [])
    if not required_status_checks:
        return [f"{ruleset_path.as_posix()}: required_status_checks is empty"]
    errors: list[str] = []
    for status in required_status_checks:
        errors.extend(check_context(status.get("context", ""), jobs, ruleset_path))
    return errors


def check_contexts(
    ruleset: Ruleset, jobs: dict[str, Job], ruleset_path: Path
) -> list[str]:
    """Require every status context to match only the conclusion job."""
    rules = [
        rule
        for rule in ruleset.get("rules", [])
        if rule["type"] == "required_status_checks"
    ]
    if not rules:
        return [f"{ruleset_path.as_posix()}: no required_status_checks rule"]
    errors: list[str] = []
    for rule in rules:
        errors.extend(check_rule_contexts(rule, jobs, ruleset_path))
    return errors


def check_needs(jobs: dict[str, Job], workflow_path: Path) -> list[str]:
    """Require all other job ids except documented, existing exemptions."""
    errors = [
        f"{workflow_path.as_posix()}: exempt job {job_id!r} does not exist"
        for job_id in sorted(EXEMPT_JOBS.keys() - jobs.keys())
    ]
    if "conclusion" not in jobs:
        errors.append(f"{workflow_path.as_posix()}: conclusion job does not exist")
        return errors
    needs = jobs["conclusion"].get("needs", [])
    if isinstance(needs, str):
        errors.append(
            f"{workflow_path.as_posix()}: conclusion needs must be a list of job ids"
        )
        needs = list[str]()
    errors.extend(
        f"{workflow_path.as_posix()}: conclusion needs is missing job {job_id!r}"
        for job_id in sorted(
            jobs.keys() - {"conclusion"} - set(needs) - EXEMPT_JOBS.keys()
        )
    )
    return errors


def check(ruleset_path: Path, workflow_path: Path) -> list[str]:
    """Match contexts by display name and conclusion dependencies by job id."""
    try:
        ruleset = cast("Ruleset", json.loads(ruleset_path.read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        return [f"{ruleset_path.as_posix()}: {' '.join(str(error).split())}"]
    try:
        workflow: Workflow = cast(
            "Workflow", yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
        )
    except (OSError, ValueError, yaml.YAMLError) as error:
        return [f"{workflow_path.as_posix()}: {' '.join(str(error).split())}"]
    jobs = workflow.get("jobs", {})
    return check_contexts(ruleset, jobs, ruleset_path) + check_needs(
        jobs, workflow_path
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check required statuses against CI conclusion dependencies."
    )
    parser.add_argument("ruleset", type=Path)
    parser.add_argument("workflow", type=Path)
    args = parser.parse_args(argv)
    errors = check(args.ruleset, args.workflow)
    for error in errors:
        sys.stdout.write(error + "\n")
    if errors:
        return 1
    sys.stdout.write("OK: required statuses and CI conclusion dependencies agree\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
