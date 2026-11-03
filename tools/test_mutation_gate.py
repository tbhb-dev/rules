# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
"""Tests for the mutation gate."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

from tools import mutation_gate as gate

CLEAN: dict[str, object] = {
    "killed": 40,
    "survived": 0,
    "total": 42,
    "no_tests": 0,
    "skipped": 2,
    "suspicious": 0,
    "timeout": 0,
    "check_was_interrupted_by_user": False,
    "segfault": 0,
}
SCRIPT = Path(__file__).parent / "mutation_gate.py"
REAL_EXPORT = gate.export_stats


@pytest.fixture(autouse=True)
def no_export(monkeypatch: pytest.MonkeyPatch) -> None:
    """Fail fast if the gate exports when it shouldn't.

    Without this, a mutant that exports for an explicit STATS path runs the
    real mutmut inside mutmut and times out instead of failing.
    """

    def refuse() -> None:
        message = "export_stats called with an explicit stats file"
        raise AssertionError(message)

    monkeypatch.setattr(gate, "export_stats", refuse)


def stats_file(tmp_path: Path, **changes: object) -> Path:
    path = tmp_path / "stats.json"
    path.write_text(json.dumps({**CLEAN, **changes}), encoding="utf-8")
    return path


def test_clean_run_passes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert gate.main([str(stats_file(tmp_path))]) == 0
    captured = capsys.readouterr()
    assert captured.out == (
        "mutants: 42 total, 40 killed, 2 skipped\nok: every mutant was killed\n"
    )
    assert captured.err == ""


@pytest.mark.parametrize("key", gate.MUST_BE_ZERO)
def test_each_nonzero_count_fails(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], key: str
) -> None:
    assert gate.main([str(stats_file(tmp_path, **{key: 3}))]) == 1
    assert capsys.readouterr().out == (
        f"mutants: 42 total, 40 killed, 2 skipped\nFAIL: 3 {key}\n"
    )


def test_problems_are_listed_together(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = stats_file(tmp_path, survived=2, timeout=1)
    assert gate.main([str(path)]) == 1
    assert capsys.readouterr().out.endswith("FAIL: 2 survived, 1 timeout\n")


def test_interrupted_run_fails(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = stats_file(tmp_path, check_was_interrupted_by_user=True)
    assert gate.main([str(path)]) == 1
    assert capsys.readouterr().out.endswith("FAIL: run was interrupted\n")


def test_interrupted_key_is_optional(tmp_path: Path) -> None:
    data = {k: v for k, v in CLEAN.items() if k != "check_was_interrupted_by_user"}
    path = tmp_path / "stats.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    assert gate.main([str(path)]) == 0


def test_empty_run_fails(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    path = stats_file(tmp_path, total=0, killed=0, skipped=0)
    assert gate.main([str(path)]) == 1
    assert capsys.readouterr().out.endswith("FAIL: no mutants were generated\n")


def test_unchecked_mutants_fail(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # What a failed stats pass leaves behind: nothing ran, nothing counted.
    path = stats_file(tmp_path, total=3280, killed=0, skipped=0)
    assert gate.main([str(path)]) == 1
    assert capsys.readouterr().out == (
        "mutants: 3280 total, 0 killed, 0 skipped\nFAIL: 3280 not checked\n"
    )


def test_unchecked_count_subtracts_the_accounted_mutants(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = stats_file(tmp_path, total=10, killed=7, skipped=0)
    assert gate.main([str(path)]) == 1
    assert capsys.readouterr().out.endswith("FAIL: 3 not checked\n")


def test_one_unchecked_mutant_fails(tmp_path: Path) -> None:
    assert gate.main([str(stats_file(tmp_path, total=43))]) == 1


def test_survivors_are_not_also_reported_as_unchecked(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = stats_file(tmp_path, killed=37, survived=3)
    assert gate.main([str(path)]) == 1
    assert capsys.readouterr().out.endswith("FAIL: 3 survived\n")


def fake_export(
    monkeypatch: pytest.MonkeyPatch,
    code: int = 0,
    stderr: str = "",
    writes: Path | None = None,
) -> list[tuple[list[str], dict[str, object]]]:
    calls: list[tuple[list[str], dict[str, object]]] = []
    monkeypatch.setattr(gate, "export_stats", REAL_EXPORT)

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append((command, kwargs))
        if writes:
            (writes / "mutants").mkdir()
            (writes / "mutants" / "mutmut-cicd-stats.json").write_text(
                json.dumps(CLEAN), encoding="utf-8"
            )
        return subprocess.CompletedProcess(command, code, "", stderr)

    monkeypatch.setattr(gate.subprocess, "run", run)
    return calls


def test_default_path_is_the_mutmut_output(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert Path("mutants/mutmut-cicd-stats.json") == gate.DEFAULT_STATS
    (tmp_path / "mutants").mkdir()
    (tmp_path / "mutants" / "mutmut-cicd-stats.json").write_text(
        json.dumps(CLEAN), encoding="utf-8"
    )
    monkeypatch.chdir(tmp_path)
    fake_export(monkeypatch)
    assert gate.main([]) == 0
    assert "ok:" in capsys.readouterr().out


def test_gate_exports_the_stats_before_reading_them(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(tmp_path)
    calls = fake_export(monkeypatch, writes=tmp_path)
    assert gate.main([]) == 0
    assert calls == [
        (
            [sys.executable, "-m", "mutmut", "export-cicd-stats"],
            {"capture_output": True, "text": True, "check": False},
        )
    ]


def test_an_explicit_stats_file_is_not_exported(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls = fake_export(monkeypatch)
    assert gate.main([str(stats_file(tmp_path))]) == 0
    assert calls == []


def test_a_failed_export_stops_the_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    fake_export(monkeypatch, code=1, stderr="no mutants run yet\n")
    with pytest.raises(
        SystemExit, match=r"^mutmut export-cicd-stats failed: no mutants run yet$"
    ):
        gate.main([])


def test_export_really_runs_mutmut() -> None:
    done = subprocess.run(
        [sys.executable, "-m", "mutmut", "export-cicd-stats", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert done.returncode == 0


def test_too_many_arguments_is_a_usage_error(
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert gate.main(["a", "b"]) == 2
    captured = capsys.readouterr()
    assert (captured.out, captured.err) == ("", "usage: mutation_gate.py [STATS]\n")


def test_missing_file_is_reported(tmp_path: Path) -> None:
    with pytest.raises(SystemExit, match=r"^cannot read .*missing\.json: "):
        gate.main([str(tmp_path / "missing.json")])


def test_invalid_json_is_reported(tmp_path: Path) -> None:
    path = tmp_path / "bad.json"
    path.write_text("{", encoding="utf-8")
    with pytest.raises(SystemExit, match=r"^cannot read .*bad\.json: "):
        gate.main([str(path)])


def test_non_object_is_reported(tmp_path: Path) -> None:
    path = tmp_path / "list.json"
    path.write_text("[]", encoding="utf-8")
    with pytest.raises(SystemExit, match=r"^.*list\.json is not a JSON object$"):
        gate.main([str(path)])


def test_missing_keys_are_reported(tmp_path: Path) -> None:
    path = tmp_path / "partial.json"
    path.write_text(json.dumps({"killed": 1, "total": 1}), encoding="utf-8")
    with pytest.raises(
        SystemExit,
        match=r"partial\.json lacks skipped, survived, timeout, suspicious, "
        r"no_tests, segfault$",
    ):
        gate.main([str(path)])


def test_script_runs_as_main(tmp_path: Path) -> None:
    done = subprocess.run(
        [sys.executable, str(SCRIPT), str(stats_file(tmp_path, survived=1))],
        capture_output=True,
        text=True,
        check=False,
    )
    assert done.returncode == 1
    assert done.stdout.endswith("FAIL: 1 survived\n")
