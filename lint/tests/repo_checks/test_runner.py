# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import shutil
import subprocess  # nosec B404
import sys
from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from pathlib import Path

CHECKS = """\
[[check]]
name = "range"
target = "@tbhb_rules//lint:range"
argument_form = "merge-base"
runs_locally = true

[[check]]
name = "first"
target = "@tbhb_rules//lint:first"
argument_form = "none"
runs_locally = true

[[check]]
name = "middle"
target = "@tbhb_rules//lint:middle"
argument_form = "base-head"
runs_locally = true

[[check]]
name = "workflow"
target = "@tbhb_rules//lint:workflow"
argument_form = "stdin"
runs_locally = false
reason = "Needs PR text."

[[check]]
name = "last"
target = "@tbhb_rules//lint:last"
argument_form = "base-head-branch"
runs_locally = true
"""


@pytest.mark.parametrize("case", ["pass", "failure", "bad-config"])
def test_runner(tmp_path: Path, case: str) -> None:
    script = tmp_path / "repo_checks.py"
    shutil.copyfile("lint/repo_checks.py", script)
    config = CHECKS.replace('"stdin"', '"unknown"') if case == "bad-config" else CHECKS
    script.with_suffix(".toml").write_text(config, encoding="utf-8")
    bazelisk = tmp_path / "bazelisk"
    bazelisk.write_text(
        """#!/bin/sh
set -eu
test "$PWD" = "$BUILD_WORKSPACE_DIRECTORY"
test "$1" = run
target=$2
shift 2
case "$target" in
    *:range) test "$*" = '-- --local origin/main HEAD'; echo merge-sha ;;
    *:first) test "$#" = 0; echo 'first output' ;;
    *:middle)
        test "$*" = '-- merge-sha HEAD'
        echo 'middle output'
        test "$CASE" != failure
        ;;
    *:last) test "$*" = '-- merge-sha HEAD agent/pr'; echo 'last output' ;;
    *) exit 99 ;;
esac
""",
        encoding="utf-8",
    )
    bazelisk.chmod(0o755)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    result = subprocess.run(  # nosec B603
        [sys.executable, str(script), "origin/main", "HEAD", "agent/pr"],
        env=os.environ
        | {
            "BUILD_WORKSPACE_DIRECTORY": str(workspace),
            "CASE": case,
            "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        },
        capture_output=True,
        text=True,
        check=False,
    )
    if case == "bad-config":
        assert result.returncode == 2
        assert "workflow: invalid argument form 'unknown'" in result.stderr
        assert not result.stdout
        return

    assert not result.stderr
    assert result.returncode == (1 if case == "failure" else 0)
    middle = "FAIL middle" if case == "failure" else "PASS middle"
    summary = (
        "3 passed, 1 failed (middle)" if case == "failure" else "4 passed, 0 failed"
    )
    assert result.stdout.splitlines() == [
        "merge-sha",
        "PASS range",
        "first output",
        "PASS first",
        "middle output",
        middle,
        "last output",
        "PASS last",
        f"repo_checks: {summary}",
    ]
