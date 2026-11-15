# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import subprocess
import sys
from pathlib import Path

import pytest


def test_workflow_checks_consumer_mapping() -> None:
    workflow = Path(".github/workflows/repo-checks.yml").read_text()
    assert "bazelisk run @tbhb_rules//lint:gitleaks_guard" in workflow


def test_empty_effective_config_fails(tmp_path: Path) -> None:
    base = tmp_path / "base.toml"
    local = tmp_path / "local.toml"
    base.write_text("")
    local.write_text("")
    result = subprocess.run(
        [
            sys.executable,
            "lint/private/gitleaks_config.py",
            str(base),
            str(local),
            str(tmp_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "zero rules; refusing to scan" in result.stderr


@pytest.mark.parametrize(
    "filename", ["BUILD.bazel", "tools.bzl", "bazel_env", "lint/private/tools.bzl"]
)
@pytest.mark.parametrize(("case", "status"), [("clean", 0), ("raw", 1)])
def test_tracked_consumer_mapping(
    tmp_path: Path, filename: str, case: str, status: int
) -> None:
    fixture = Path("lint/tests/gitleaks_guard/testdata") / case / "tools.bzl"
    (tmp_path / filename).parent.mkdir(parents=True, exist_ok=True)
    (tmp_path / filename).write_text(fixture.read_text())
    (tmp_path / "MODULE.bazel").write_text(
        'module(name = "consumer")\nbazel_dep(name = "tbhb_rules")\n'
    )
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "add", filename], check=True)
    # An untracked raw mapping must not affect the result.
    (tmp_path / "untracked.bzl").write_text(
        'tools = {"gitleaks": "@tbhb_rules_gitleaks//:gitleaks"}'
    )
    result = subprocess.run(
        [sys.executable, "lint/private/gitleaks_guard.py"],
        env=os.environ | {"BUILD_WORKSPACE_DIRECTORY": str(tmp_path)},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status
    if status:
        assert (
            f"{filename}:7: gitleaks_guard: use @tbhb_rules//lint:gitleaks"
            in result.stderr
        )


@pytest.mark.parametrize("local", [False, True])
def test_wrapper_refuses_empty_rules(tmp_path: Path, local: bool) -> None:
    root = Path.cwd()
    script = (root / "lint/private/gitleaks_tool.sh.tpl").read_text()
    (tmp_path / "base.toml").write_text("")
    prepare = tmp_path / "prepare"
    prepare.write_text(
        f'#!/bin/sh\nexec "{sys.executable}" '
        f'"{root}/lint/private/gitleaks_config.py" "$@"\n'
    )
    prepare.chmod(0o755)
    (tmp_path / "_main").symlink_to(tmp_path, target_is_directory=True)
    if local:
        (tmp_path / ".gitleaks.toml").write_text("")
    for key, value in {
        "SELF": "wrapper.sh",
        "GITLEAKS": "must-not-run",
        "BASE": "base.toml",
        "PREPARE": "prepare",
        "REQUIRED": "",
    }.items():
        script = script.replace(f"@@{key}@@", value)
    wrapper = tmp_path / "wrapper.sh"
    wrapper.write_text(script)
    result = subprocess.run(
        ["bash", str(wrapper), "stdin"],
        cwd=tmp_path,
        env=os.environ | {"RUNFILES_DIR": str(tmp_path)},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert (
        "gitleaks_tool: FAIL: effective gitleaks config has zero rules" in result.stderr
    )
