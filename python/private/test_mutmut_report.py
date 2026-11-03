# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import subprocess
import sys
from pathlib import Path

import pytest

from private import mutmut_report as mr

ALL_KILLED: dict[str, object] = {
    "total": 4,
    "killed": 3,
    "skipped": 1,
    "survived": 0,
    "timeout": 0,
    "suspicious": 0,
    "no_tests": 0,
    "segfault": 0,
    "check_was_interrupted_by_user": False,
}


def test_mutmut_runs_the_module_and_appends_to_the_log(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[tuple[list[str], dict[str, object]]] = []

    def fake_run(
        command: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 2, "out\n", "err\n")

    monkeypatch.setattr(mr.subprocess, "run", fake_run)
    log = tmp_path / "log"
    log.write_text("before\n")
    done = mr.mutmut(["results", "--all", "true"], log)
    assert done.returncode == 2
    assert calls == [
        (
            [sys.executable, "-m", "mutmut", "results", "--all", "true"],
            {"capture_output": True, "text": True, "check": False},
        ),
    ]
    assert log.read_text() == (
        "before\n$ mutmut results --all true (exit 2)\nout\nerr\n\n"
    )


def test_load_stats(tmp_path: Path) -> None:
    path = tmp_path / "stats.json"
    assert mr.load_stats(path) is None
    path.write_text("not json")
    assert mr.load_stats(path) is None
    path.write_text("[1]")
    assert mr.load_stats(path) is None
    path.write_text(json.dumps(ALL_KILLED))
    assert mr.load_stats(path) == ALL_KILLED


def test_report_without_stats_is_an_interrupted_run() -> None:
    assert mr.report(None, "") == (
        "total=0\nkilled=0\nlived=0\nnot_covered=0\ntimeout=0\nerrored=0\n"
        "skipped=0\ninterrupted=1\n"
    )


def test_report_lists_counts_and_the_mutants_not_killed() -> None:
    stats: dict[str, object] = ALL_KILLED | {
        "survived": 2,
        "no_tests": 3,
        "timeout": 4,
        "suspicious": 5,
        "segfault": 6,
        "caught_by_type_check": 7,
        "check_was_interrupted_by_user": True,
    }
    del stats["skipped"]
    results = (
        "    tools.a.x__mutmut_1: killed\n"
        "    tools.a.x__mutmut_2: survived\n"
        "    tools.a.y__mutmut_1: no tests\n"
        "    tools.a.y__mutmut_2: not checked\n"
        "    tools.a.y__mutmut_3: timeout\n"
        "    tools.a.y__mutmut_4: suspicious\n"
        "    tools.a.y__mutmut_5: segfault\n"
        "    tools.a.y__mutmut_6: skipped\n"
        "    tools.a.y__mutmut_7: caught by type check\n"
        "    : survived\n"
        "    tools.b: odd.x__mutmut_1: survived\n"
        "noise without a status\n"
        "    tools.a.z__mutmut_1: something else\n"
    )
    assert mr.report(stats, results) == (
        "total=4\nkilled=3\nlived=2\nnot_covered=3\ntimeout=4\nerrored=11\n"
        "skipped=7\ninterrupted=1\n"
        "mutant.survived=tools.a.x__mutmut_2\n"
        "mutant.no_tests=tools.a.y__mutmut_1\n"
        "mutant.not_checked=tools.a.y__mutmut_2\n"
        "mutant.timeout=tools.a.y__mutmut_3\n"
        "mutant.suspicious=tools.a.y__mutmut_4\n"
        "mutant.segfault=tools.a.y__mutmut_5\n"
        "mutant.skipped=tools.a.y__mutmut_6\n"
        "mutant.caught_by_type_check=tools.a.y__mutmut_7\n"
        "mutant.survived=tools.b: odd.x__mutmut_1\n"
    )


def test_report_counts_type_check_rejects_as_skipped_not_killed() -> None:
    stats: dict[str, object] = {"total": 2, "killed": 1, "caught_by_type_check": 1}
    lines = mr.report(stats, "    m__mutmut_2: caught by type check\n").splitlines()
    assert "killed=1" in lines
    assert "skipped=1" in lines
    assert "mutant.caught_by_type_check=m__mutmut_2" in lines


def test_report_counts_missing_stats_as_zero() -> None:
    assert mr.report({}, "") == (
        "total=0\nkilled=0\nlived=0\nnot_covered=0\ntimeout=0\nerrored=0\n"
        "skipped=0\ninterrupted=0\n"
    )


def test_report_of_a_clean_run() -> None:
    assert mr.report(ALL_KILLED, "    m__mutmut_1: killed\n").endswith(
        "skipped=1\ninterrupted=0\n",
    )


@pytest.mark.parametrize("argv", [[], ["one"], ["a", "b", "c"]])
def test_main_needs_a_report_and_a_log(
    argv: list[str],
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Calling mutmut would raise, so a usage error must stop before it.
    monkeypatch.setattr(mr, "mutmut", None)
    assert mr.main(argv) == 2
    assert capsys.readouterr().err == "usage: mutmut_report.py REPORT LOG\n"


@pytest.fixture
def fake_mutmut(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> list[list[str]]:
    monkeypatch.chdir(tmp_path)
    calls: list[list[str]] = []
    export_status = {"code": 0}

    def fake(args: list[str], log: Path) -> subprocess.CompletedProcess[str]:
        calls.append(args)
        assert log == Path("log")
        out = "    m__mutmut_1: survived\n" if args[0] == "results" else ""
        code = export_status["code"] if args[0] == "export-cicd-stats" else 0
        return subprocess.CompletedProcess(args, code, out, "")

    monkeypatch.setattr(mr, "mutmut", fake)
    monkeypatch.setattr(mr, "export_status", export_status, raising=False)
    return calls


def test_main_writes_the_report_from_the_stats(
    fake_mutmut: list[list[str]],
) -> None:
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(json.dumps(ALL_KILLED | {"survived": 1, "total": 5}))
    Path("log").write_text("stale")
    Path("pyproject.toml").write_text("[tool.mutmut]\nsource_paths = []\n")
    assert mr.main(["report", "log"]) == 0
    assert fake_mutmut == [["run"], ["export-cicd-stats"], ["results", "--all", "true"]]
    assert Path("pyproject.toml").read_text() == (
        "[tool.mutmut]\nuse_git_change_detection = false\nsource_paths = []\n"
    )
    assert Path("log").read_text() == ""
    assert Path("report").read_text().splitlines() == [
        "total=5",
        "killed=3",
        "lived=1",
        "not_covered=0",
        "timeout=0",
        "errored=0",
        "skipped=1",
        "interrupted=0",
        "mutant.survived=m__mutmut_1",
    ]


def test_main_reports_an_interrupted_run_when_the_export_fails(
    fake_mutmut: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(json.dumps(ALL_KILLED))
    export_status = getattr(mr, "export_status")  # noqa: B009
    export_status["code"] = 1
    read: list[Path] = []
    monkeypatch.setattr(mr, "load_stats", read.append)
    Path("log").write_text("")
    assert mr.main(["report", "log"]) == 1
    assert "interrupted=1" in Path("report").read_text().splitlines()
    assert len(fake_mutmut) == 3
    assert read == []


NO_GIT = "use_git_change_detection = false\n"


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("[tool.mutmut]\n", "[tool.mutmut]\n" + NO_GIT),
        (
            "[project]\n  [tool.mutmut]  \nx = 1\n",
            "[project]\n  [tool.mutmut]  \n" + NO_GIT + "x = 1\n",
        ),
        ("[tool.mutmut]\nuse_git_change_detection = true\n", None),
        ("[tool.mutmut.extra]\n", None),
        (
            "[tool.mutmut]\n[tool.mutmut]\n",
            "[tool.mutmut]\n" + NO_GIT + "[tool.mutmut]\n",
        ),
    ],
)
def test_scratch_config(tmp_path: Path, text: str, expected: str | None) -> None:
    path = tmp_path / "pyproject.toml"
    path.write_text(text)
    mr.scratch_config(path)
    assert path.read_text() == (text if expected is None else expected)


def test_scratch_config_without_a_pyproject(tmp_path: Path) -> None:
    mr.scratch_config(tmp_path / "pyproject.toml")
    assert not (tmp_path / "pyproject.toml").exists()


@pytest.mark.parametrize(
    ("counts", "expected"),
    [
        ({}, []),
        ({"timeout": "2"}, ["timeout"]),
        ({"errored": "1", "timeout": "1"}, ["timeout", "errored"]),
        ({"interrupted": "1", "lived": "3"}, ["interrupted"]),
    ],
)
def test_unstable(counts: dict[str, str], expected: list[str]) -> None:
    keys = ["total", *mr.STATS_KEYS, "interrupted"]
    base = dict.fromkeys(keys, "0") | counts
    text = "".join(f"{key}={value}\n" for key, value in base.items())
    assert mr.unstable(text + "mutant.survived=a=b\n") == expected


def test_main_fails_an_unstable_run_and_shows_the_log(
    fake_mutmut: list[list[str]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(json.dumps(ALL_KILLED | {"timeout": 1, "segfault": 2}))
    Path("pyproject.toml").write_text("")
    assert mr.main(["report", "log"]) == 1
    assert len(fake_mutmut) == 3
    assert capsys.readouterr().err == (
        "mutmut_report: not cacheable: timeout, errored\n"
    )
