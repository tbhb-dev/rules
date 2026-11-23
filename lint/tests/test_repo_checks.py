# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

from lint.repo_checks import TARGET, read_checks

ROOT = Path(__file__).absolute().parents[2]
RUN = re.compile(rf"\bbazelisk\s+run\s+['\"]?({TARGET.pattern})")


def test_workflow_drift() -> None:
    workflow = yaml.safe_load((ROOT / ".github/workflows/repo-checks.yml").read_text())
    known = set((ROOT / "repo_check_targets.txt").read_text().splitlines())
    known.update((ROOT / "lint/repo_check_targets.txt").read_text().splitlines())
    checks = read_checks(ROOT / "lint/repo_checks.toml")
    configured = {check.target for check in checks}
    workflow_targets = set()
    for job in workflow["jobs"].values():
        for step in job.get("steps", []):
            run = step.get("run", "").replace("\\\n", " ")
            for line in run.splitlines():
                if not line.lstrip().startswith("#"):
                    workflow_targets.update(RUN.findall(line))

    # The workflow also calls root targets that each consumer defines.
    missing = {t for t in workflow_targets if t.startswith("@") or t in known}
    assert not (missing - configured), sorted(missing - configured)
    unknown = {target.removeprefix("@tbhb_rules") for target in configured} - known
    assert not unknown, sorted(unknown)


@pytest.mark.parametrize(
    ("scenario", "status"), [("pass", 0), ("fail", 1), ("bad-config", 2)]
)
def test_runner(tmp_path: Path, scenario: str, status: int) -> None:
    runner = tmp_path / "repo_checks.py"
    shutil.copyfile(ROOT / "lint/repo_checks.py", runner)
    config = ""
    for name, args in [
        ("first", "none"),
        ("second", "base-head"),
        ("third", "base-head-branch"),
    ]:
        config += f"""\n[[checks]]
name = "{name}"
target = "@tbhb_rules//lint:{name}"
args = "{args}"
runs_locally = true
"""
    if scenario == "bad-config":
        config = config.replace('args = "none"', 'args = "unknown"')
    runner.with_suffix(".toml").write_text(config)
    bazelisk = tmp_path / "bazelisk"
    bazelisk.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALLS"
if [[ ${4:-} == --ref ]]; then
  echo merged
else
  echo "output from $2"
fi
[[ $2 != "$FAIL_TARGET" ]]
""")
    bazelisk.chmod(0o755)
    calls = tmp_path / "calls"
    env = os.environ | {
        "BUILD_WORKSPACE_DIRECTORY": str(tmp_path),
        "CALLS": str(calls),
        "FAIL_TARGET": "@tbhb_rules//lint:second" if scenario == "fail" else "",
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
    }
    branch = ["agent/example"] if scenario == "fail" else []
    result = subprocess.run(
        [sys.executable, str(runner), "origin/main", "HEAD", *branch],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status, (result.stdout, result.stderr)
    if status == 2:
        assert "unsupported args" in result.stderr
        assert not calls.exists()
        return

    assert calls.read_text().splitlines() == [
        "run @tbhb_rules//lint:pr_merge_base -- --ref origin/main HEAD",
        "run @tbhb_rules//lint:first",
        "run @tbhb_rules//lint:second -- merged HEAD",
        " ".join(["run @tbhb_rules//lint:third -- merged HEAD", *branch]),
    ]
    assert result.stdout.splitlines() == [
        "output from @tbhb_rules//lint:first",
        "PASS first",
        "output from @tbhb_rules//lint:second",
        "FAIL second" if status else "PASS second",
        "output from @tbhb_rules//lint:third",
        "PASS third",
        "repo_checks: 2 passed, 1 failed (second)"
        if status
        else "repo_checks: 3 passed, 0 failed",
    ]
