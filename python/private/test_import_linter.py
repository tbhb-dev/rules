# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import subprocess
import sys

import pytest

from private import import_linter

KEPT = "Analyzed 11 files, 7 dependencies.\n\nContracts: 3 kept, 0 broken.\n"


@pytest.mark.parametrize(
    ("output", "expected"),
    [
        (KEPT, []),
        ("Analyzed 2 files, 0 dependencies.\nContracts: 0 kept, 1 broken.\n", []),
        ("Analyzed 2 files, 0 dependencies.\nContracts: 1 kept, 1 broken.\n", []),
        (
            "Analyzed 11 files, 7 dependencies.\nContracts: 0 kept, 0 broken.\n",
            ["no contract is defined"],
        ),
        (
            "Analyzed 0 files, 0 dependencies.\nContracts: 1 kept, 0 broken.\n",
            ["no module was analysed"],
        ),
        ("", ["no module was analysed", "no contract is defined"]),
        (
            "  Analyzed 3 files\n  Contracts: 1 kept, 0 broken.\n",
            ["no module was analysed", "no contract is defined"],
        ),
    ],
)
def test_problems(output: str, expected: list[str]) -> None:
    assert import_linter.problems(output) == expected


def fake_run(
    monkeypatch: pytest.MonkeyPatch,
    code: int,
    stdout: str,
) -> list[tuple[list[str], dict[str, object]]]:
    calls: list[tuple[list[str], dict[str, object]]] = []

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, code, stdout, "err\n")

    monkeypatch.setattr(import_linter.subprocess, "run", run)
    return calls


def test_main_passes_a_run_that_checked_contracts(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    calls = fake_run(monkeypatch, 0, KEPT)
    assert import_linter.main(["--config", "x.toml"]) == 0
    assert calls == [
        (
            [
                sys.executable,
                "-c",
                import_linter.COMMAND,
                "--no-cache",
                "--config",
                "x.toml",
            ],
            {"capture_output": True, "text": True, "check": False},
        ),
    ]
    assert capsys.readouterr() == (KEPT, "err\n")


def test_main_returns_the_status_of_a_failed_run(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake_run(monkeypatch, 3, "")
    assert import_linter.main([]) == 3
    assert capsys.readouterr() == ("", "err\n")


def test_main_fails_a_run_that_checked_nothing(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    out = "Analyzed 4 files, 1 dependencies.\nContracts: 0 kept, 0 broken.\n"
    fake_run(monkeypatch, 0, out)
    assert import_linter.main([]) == 1
    assert capsys.readouterr() == (
        out,
        "err\nimport_linter: FAIL: no contract is defined\n",
    )


def test_main_names_every_problem(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake_run(monkeypatch, 0, "")
    assert import_linter.main([]) == 1
    assert capsys.readouterr().err.endswith(
        "import_linter: FAIL: no module was analysed, no contract is defined\n",
    )


def test_the_command_runs_lint_imports() -> None:
    assert "lint_imports_command()" in import_linter.COMMAND
    compile(import_linter.COMMAND, "<command>", "exec")
