# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import subprocess
import sys
from pathlib import Path

import pytest

from private import pip_audit


def test_commands_export_the_lock_and_audit_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("TBHB_PYTHON_UV", "/env/uv")
    work = Path("/work")
    export, audit = pip_audit.commands(work, ["--strict"])
    assert " ".join(export) == (
        "/env/uv export --quiet --frozen --all-packages --all-groups"
        f" --no-emit-workspace --format pylock.toml -o {work / 'pylock.toml'}"
    )
    assert audit[:3] == [sys.executable, "-m", "pip_audit"]
    assert audit[3:] == [
        "--cache-dir",
        str(work / "cache"),
        "--locked",
        str(work),
        "--strict",
    ]


@pytest.fixture
def runs(monkeypatch: pytest.MonkeyPatch) -> list[tuple[list[str], dict[str, object]]]:
    monkeypatch.setenv("TBHB_PYTHON_UV", "/env/uv")
    calls: list[tuple[list[str], dict[str, object]]] = []
    codes = iter([0, 4])

    def fake_run(
        command: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        calls.append((command, kwargs | {"cwd": Path.cwd()}))
        return subprocess.CompletedProcess(command, next(codes))

    monkeypatch.setattr(pip_audit.subprocess, "run", fake_run)
    return calls


def test_main_audits_from_the_workspace(
    runs: list[tuple[list[str], dict[str, object]]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    assert pip_audit.main(["-v"]) == 4
    (export, export_kwargs), (audit, audit_kwargs) = runs
    assert export[0] == "/env/uv"
    assert export_kwargs["check"] is False
    env = export_kwargs["env"]
    assert isinstance(env, dict)
    assert env["UV_NO_CONFIG"] == "1"
    assert env["TBHB_PYTHON_UV"] == "/env/uv"
    assert export_kwargs["cwd"] == tmp_path
    assert audit[-1] == "-v"
    assert audit_kwargs == {"check": False, "cwd": tmp_path}
    work = Path(audit[-2])
    assert export[-1] == str(work / "pylock.toml")
    assert not work.exists()


def test_main_stays_put_outside_bazel_run(
    runs: list[tuple[list[str], dict[str, object]]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.delenv("BUILD_WORKSPACE_DIRECTORY", raising=False)
    monkeypatch.chdir(tmp_path)
    assert pip_audit.main([]) == 4
    assert [kwargs["cwd"] for _, kwargs in runs] == [tmp_path, tmp_path]
    assert Path(os.getcwd()) == tmp_path  # noqa: PTH109


def test_main_stops_when_the_export_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("TBHB_PYTHON_UV", "/env/uv")
    monkeypatch.delenv("BUILD_WORKSPACE_DIRECTORY", raising=False)
    calls: list[list[str]] = []

    def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        calls.append(command)
        return subprocess.CompletedProcess(command, 3)

    monkeypatch.setattr(pip_audit.subprocess, "run", fake_run)
    assert pip_audit.main([]) == 3
    assert len(calls) == 1
