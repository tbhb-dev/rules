# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# ruff: noqa: INP001
"""Run the local repository checks in registry order."""

import os
import re
import shutil
import subprocess  # nosec B404
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

LOCAL_FORMS = {"none", "merge-base", "base-head", "base-head-branch"}
WORKFLOW_FORMS = {"stdin", "scan-mode", "online-workflow-audit"}
NAME = re.compile(r"[a-zA-Z0-9_.+-]+")
TARGET = re.compile(r"(?:@tbhb_rules//lint:|//:)" + NAME.pattern)


@dataclass(frozen=True)
class Check:
    name: str
    target: str
    argument_form: str
    runs_locally: bool


def parse_check(entry: object) -> Check:
    if not isinstance(entry, dict):
        msg = "expected a check table"
        raise TypeError(msg)
    name = entry.get("name")
    target = entry.get("target")
    form = entry.get("argument_form")
    local = entry.get("runs_locally")
    reason = entry.get("reason")
    if not isinstance(name, str) or not NAME.fullmatch(name):
        msg = f"invalid check name {name!r}"
        raise ValueError(msg)
    if not isinstance(target, str) or not TARGET.fullmatch(target):
        msg = f"{name}: invalid target {target!r}"
        raise ValueError(msg)
    forms = LOCAL_FORMS if local else LOCAL_FORMS | WORKFLOW_FORMS
    if not isinstance(form, str) or form not in forms:
        msg = f"{name}: invalid argument form {form!r}"
        raise ValueError(msg)
    if not isinstance(local, bool):
        msg = f"{name}: runs_locally must be a boolean"
        raise TypeError(msg)
    if not local and (not isinstance(reason, str) or not reason.strip()):
        msg = f"{name}: a workflow-only check needs a reason"
        raise ValueError(msg)
    return Check(name, target, form, local)


def load_checks(config: Path) -> list[Check]:
    with config.open("rb") as source:
        entries = tomllib.load(source).get("check")
    if not isinstance(entries, list) or not entries:
        msg = "expected at least one [[check]] entry"
        raise ValueError(msg)
    checks = [parse_check(entry) for entry in entries]
    if len({check.name for check in checks}) != len(checks) or len(
        {check.target for check in checks}
    ) != len(checks):
        msg = "check names and targets must be unique"
        raise ValueError(msg)
    forms = [check.argument_form for check in checks if check.runs_locally]
    if forms[:1] != ["merge-base"] or forms.count("merge-base") != 1:
        msg = "the first local check must be the only local merge-base helper"
        raise ValueError(msg)
    return checks


def run_checks(
    checks: list[Check], workspace: Path, bazelisk: str, args: list[str]
) -> int:
    base, head, *branch = args
    helper, *local_checks = (check for check in checks if check.runs_locally)
    result = subprocess.run(  # noqa: S603  # nosec B603
        [bazelisk, "run", helper.target, "--", "--local", base, head],
        cwd=workspace,
        check=False,
        stdout=subprocess.PIPE,
        text=True,
    )
    merge_base = result.stdout.strip()
    if result.returncode or not merge_base:
        sys.stderr.write(
            f"{helper.name}: could not resolve a merge base for {base!r} and {head!r}\n"
        )
        print(f"FAIL {helper.name}", flush=True)  # noqa: T201
        print(f"repo_checks: 0 passed, 1 failed ({helper.name})", flush=True)  # noqa: T201
        return 2
    print(merge_base, flush=True)  # noqa: T201
    print(f"PASS {helper.name}", flush=True)  # noqa: T201
    arguments = {
        "none": [],
        "base-head": ["--", merge_base, head],
        "base-head-branch": ["--", merge_base, head, *branch],
    }
    failed = []
    for check in local_checks:
        command = [bazelisk, "run", check.target, *arguments[check.argument_form]]
        try:
            status = subprocess.run(command, cwd=workspace, check=False).returncode  # noqa: S603  # nosec B603
        except OSError as error:
            sys.stderr.write(f"{check.name}: {error}\n")
            status = 1
        if status:
            failed.append(check.name)
        print(f"{'FAIL' if status else 'PASS'} {check.name}", flush=True)  # noqa: T201
    passed = 1 + len(local_checks) - len(failed)
    summary = f"repo_checks: {passed} passed, {len(failed)} failed"
    if failed:
        summary += f" ({', '.join(failed)})"
    print(summary, flush=True)  # noqa: T201
    return int(bool(failed))


def main(args: list[str]) -> int:
    if len(args) not in {2, 3} or not all(args):
        sys.stderr.write("usage: repo_checks BASE HEAD [HEAD_BRANCH]\n")
        return 2
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    bazelisk = shutil.which("bazelisk")
    if not workspace or not bazelisk:
        sys.stderr.write("repo_checks: run this target with bazelisk run\n")
        return 2
    try:
        checks = load_checks(Path(__file__).with_suffix(".toml"))
        return run_checks(checks, Path(workspace), bazelisk, args)
    except (OSError, TypeError, ValueError) as error:
        sys.stderr.write(f"repo_checks: {error}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
