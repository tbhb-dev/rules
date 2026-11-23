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
    workflow_targets = []
    for job in workflow["jobs"].values():
        for step in job.get("steps", []):
            run = step.get("run", "").replace("\\\n", " ")
            for line in run.splitlines():
                if not line.lstrip().startswith("#"):
                    workflow_targets.extend(RUN.findall(line))

    runner = "@tbhb_rules//lint:repo_checks"
    assert workflow_targets.count(runner) == 1
    direct_targets = set(workflow_targets) - {runner}
    local_targets = {check.target for check in checks if check.runs_locally}
    duplicated = direct_targets & local_targets
    assert not duplicated, sorted(duplicated)

    # The workflow also calls root targets that each consumer defines.
    missing = {t for t in direct_targets if t.startswith("@") or t in known}
    assert not (missing - configured), sorted(missing - configured)
    unknown = {target.removeprefix("@tbhb_rules") for target in configured} - known
    assert not unknown, sorted(unknown)


@pytest.mark.parametrize(
    ("scenario", "status"),
    [("pass", 0), ("pull-request", 0), ("fail", 1), ("bad-config", 2)],
)
def test_runner(tmp_path: Path, scenario: str, status: int) -> None:
    runner = tmp_path / "repo_checks.py"
    shutil.copyfile(ROOT / "lint/repo_checks.py", runner)
    config = ""
    for name, args in [
        ("first", "none"),
        ("second", "base-head"),
        ("third", "base-head-branch"),
        ("pr_size", "pr-base-head"),
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
if [[ $2 == @tbhb_rules//lint:pr_merge_base ]]; then
  echo merged
else
  echo "output from $2"
fi
if [[ $2 == @tbhb_rules//lint:pr_size ]]; then
  printf '%s\\n' "${MAIN_TIP-}" "${PR_AUTHOR-}" "${GH_TOKEN-}" "${REPO-}" > "$SIZE_ENV"
fi
[[ $2 != "$FAIL_TARGET" ]]
""")
    bazelisk.chmod(0o755)
    calls = tmp_path / "calls"
    size_env = tmp_path / "size_env"
    env = os.environ | {
        "BUILD_WORKSPACE_DIRECTORY": str(tmp_path),
        "CALLS": str(calls),
        "FAIL_TARGET": "@tbhb_rules//lint:second" if scenario == "fail" else "",
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        "SIZE_ENV": str(size_env),
    }
    env.pop("PR_BASE_SHA", None)
    base_args = ["origin/main"]
    helper_args = "--ref origin/main"
    size_base = "merged"
    if scenario == "pull-request":
        base_args = ["--base-branch", "main"]
        helper_args = "main"
        size_base = "event-base-sha"
        env.update(
            PR_BASE_SHA=size_base,
            MAIN_TIP="live-main-tip",
            PR_AUTHOR="pull-request-author",
            GH_TOKEN=tmp_path.name,
            REPO="owner/repo",
        )
    branch = ["agent/example"] if scenario in {"fail", "pull-request"} else []
    result = subprocess.run(
        [sys.executable, str(runner), *base_args, "HEAD", *branch],
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
        f"run @tbhb_rules//lint:pr_merge_base -- {helper_args} HEAD",
        "run @tbhb_rules//lint:first",
        "run @tbhb_rules//lint:second -- merged HEAD",
        " ".join(["run @tbhb_rules//lint:third -- merged HEAD", *branch]),
        f"run @tbhb_rules//lint:pr_size -- {size_base} HEAD",
    ]
    if scenario == "pull-request":
        assert size_env.read_text().splitlines() == [
            "live-main-tip",
            "pull-request-author",
            tmp_path.name,
            "owner/repo",
        ]
    assert result.stdout.splitlines() == [
        "output from @tbhb_rules//lint:first",
        "PASS first",
        "output from @tbhb_rules//lint:second",
        "FAIL second" if status else "PASS second",
        "output from @tbhb_rules//lint:third",
        "PASS third",
        "output from @tbhb_rules//lint:pr_size",
        "PASS pr_size",
        "repo_checks: 3 passed, 1 failed (second)"
        if status
        else "repo_checks: 4 passed, 0 failed",
    ]
