# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Run the local pull request checks from a Bazel workspace."""

import argparse
import os
import re
import subprocess  # nosec B404
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import cast

TARGET = re.compile(r"(?:@tbhb_rules//lint:|//:)[\w./+-]+")
LOCAL_ARGS = {"none", "base-head", "base-head-branch", "pr-base-head"}
ARG_FORMS = LOCAL_ARGS | {"scan-mode", "stdin", "workflow-path"}


@dataclass(frozen=True)
class Check:
    name: str
    target: str
    args: str
    runs_locally: bool


def _read_check(entry: object, index: int, names: set[str], targets: set[str]) -> Check:
    match entry:
        case dict(
            {
                "name": str(name),
                "target": str(target),
                "args": str(args),
                "runs_locally": bool(runs_locally),
            }
        ) if re.fullmatch(r"[\w.-]+", name) and TARGET.fullmatch(target):
            pass
        case _:
            msg = f"check {index} needs a name, Bazel target, args and runs_locally"
            raise ValueError(msg)
    if name in names or target in targets:
        msg = f"duplicate check name or target for {name}"
        raise ValueError(msg)
    if args not in ARG_FORMS or (runs_locally and args not in LOCAL_ARGS):
        msg = f"{name} has unsupported args {args!r}"
        raise ValueError(msg)
    if not runs_locally:
        reason: object = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            msg = f"{name} needs a reason for skipping local runs"
            raise ValueError(msg)
    return Check(name, target, args, runs_locally)


def read_checks(path: Path) -> list[Check]:
    with path.open("rb") as source:
        entries = tomllib.load(source).get("checks")
    if not isinstance(entries, list) or not entries:
        msg = "expected a nonempty [[checks]] list"
        raise ValueError(msg)

    checks: list[Check] = []
    names: set[str] = set()
    targets: set[str] = set()
    for index, entry in enumerate(cast("list[object]", entries), 1):
        check = _read_check(entry, index, names, targets)
        checks.append(check)
        names.add(check.name)
        targets.add(check.target)
    return checks


def bazel_run(
    workspace: Path, target: str, args: list[str], *, capture: bool = False
) -> subprocess.CompletedProcess[str]:
    cmd = ["bazelisk", "run", target]
    if args:
        cmd.extend(["--", *args])
    return subprocess.run(  # noqa: S603  # nosec B603
        cmd,
        cwd=workspace,
        stdout=subprocess.PIPE if capture else None,
        text=True,
        check=False,
    )


def run_checks(
    workspace: Path, base: str, head: str, branch: str | None, *, base_is_branch: bool
) -> int:
    checks = read_checks(Path(__file__).with_name("repo_checks.toml"))
    merge_base = bazel_run(
        workspace,
        "@tbhb_rules//lint:pr_merge_base",
        [base, head] if base_is_branch else ["--ref", base, head],
        capture=True,
    )
    if merge_base.returncode or not merge_base.stdout.strip():
        msg = f"could not find a merge base for {base!r} and {head!r}"
        raise ValueError(msg)

    revision_range = [merge_base.stdout.strip(), head]
    arguments = {
        "none": [],
        "base-head": revision_range,
        "pr-base-head": [os.environ.get("PR_BASE_SHA", revision_range[0]), head],
        "base-head-branch": revision_range
        if branch is None
        else [*revision_range, branch],
    }
    failures = []
    passed = 0
    for check in checks:
        if not check.runs_locally:
            continue
        result = bazel_run(workspace, check.target, arguments[check.args])
        if result.returncode:
            sys.stdout.write(f"FAIL {check.name}\n")
            failures.append(check.name)
        else:
            sys.stdout.write(f"PASS {check.name}\n")
            passed += 1
        sys.stdout.flush()

    failed_names = f" ({', '.join(failures)})" if failures else ""
    sys.stdout.write(
        f"repo_checks: {passed} passed, {len(failures)} failed{failed_names}\n"
    )
    return int(bool(failures))


def main() -> int:
    parser = argparse.ArgumentParser(prog="repo_checks", description=__doc__)
    parser.add_argument(
        "--base-branch", action="store_true", help="resolve the base branch on origin"
    )
    parser.add_argument("base")
    parser.add_argument("head")
    parser.add_argument("head_branch", nargs="?")
    args = parser.parse_args()
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace:
        parser.error("run this target with bazelisk run")
    try:
        return run_checks(
            Path(workspace),
            args.base,
            args.head,
            args.head_branch,
            base_is_branch=args.base_branch,
        )
    except (OSError, ValueError) as error:
        sys.stderr.write(f"repo_checks: {error}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
