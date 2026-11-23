# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import re
from pathlib import Path

import yaml

from lint.repo_checks import load_checks

LINT_RUN = re.compile(
    r"""\bbazelisk[ \t]+run[ \t]+['"]?(@tbhb_rules//lint:[^\s'";<>&|)]+)"""
)


def test_workflow_checks_match_registry() -> None:
    workflow = yaml.safe_load(
        Path(".github/workflows/repo-checks.yml").read_text(encoding="utf-8")
    )
    workflow_targets = {
        target
        for job in workflow["jobs"].values()
        for step in job.get("steps", [])
        for line in step.get("run", "").replace("\\\n", "").splitlines()
        if not line.lstrip().startswith("#")
        for target in LINT_RUN.findall(line)
    }
    registered = {check.target for check in load_checks(Path("lint/repo_checks.toml"))}
    existing = {
        target
        for path in ("repo_check_targets.txt", "lint/repo_check_targets.txt")
        for target in Path(path).read_text(encoding="utf-8").splitlines()
    }
    assert workflow_targets
    assert not (missing := workflow_targets - registered), sorted(missing)
    assert not (unknown := registered - existing), sorted(unknown)
