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


@pytest.fixture(autouse=True)
def timeout_cap(monkeypatch: pytest.MonkeyPatch) -> None:
    """Set the cap the action sets from quality's constant."""
    monkeypatch.setenv(mr.MAX_TIMEOUT_ENV, "10")


@pytest.fixture(autouse=True)
def no_quota(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Keep every test off the host's cgroup files and on a 16-CPU host."""
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "no" / "cpu.max")
    monkeypatch.setattr(mr, "V1_QUOTA", tmp_path / "no" / "quota")
    monkeypatch.setattr(mr, "V1_PERIOD", tmp_path / "no" / "period")
    monkeypatch.setattr(mr.os, "cpu_count", lambda: 16)


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        ("200000 100000\n", ["--max-children", "2"]),
        ("150000 100000\n", ["--max-children", "2"]),
        ("50000 100000\n", ["--max-children", "1"]),
        ("0 100000\n", ["--max-children", "1"]),
        ("1500000 100000\n", ["--max-children", "15"]),
        ("1600000 100000\n", []),
        ("9000000 100000\n", []),
        ("max 100000\n", []),
        ("", []),
        ("lots of CPUs\n", []),
        ("200000\n", []),
        ("200000 100000 5\n", []),
        ("-1 100000\n", []),
        ("200000 0\n", []),
        ("\u0662 1\n", []),
    ],
)
def test_max_children_reads_cgroup_v2(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    content: str,
    expected: list[str],
) -> None:
    (tmp_path / "cpu.max").write_text(content)
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "cpu.max")
    assert mr.max_children() == expected


def test_max_children_without_cgroup_files() -> None:
    assert mr.max_children() == []


def test_max_children_ignores_an_unreadable_file(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path)  # a directory: OSError
    assert mr.max_children() == []
    (tmp_path / "bytes").write_bytes(b"\xff\xfe")
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "bytes")  # not UTF-8
    assert mr.max_children() == []


@pytest.mark.parametrize(
    ("cpus", "expected"),
    [(None, ["--max-children", "2"]), (3, ["--max-children", "2"]), (2, [])],
)
def test_max_children_compares_with_the_cpu_count(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    cpus: int | None,
    expected: list[str],
) -> None:
    (tmp_path / "cpu.max").write_text("200000 100000\n")
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "cpu.max")
    monkeypatch.setattr(mr.os, "cpu_count", lambda: cpus)
    assert mr.max_children() == expected


@pytest.mark.parametrize(
    ("quota", "period", "expected"),
    [
        ("200000", "100000", ["--max-children", "2"]),
        ("-1", "100000", []),
        ("200000", "", []),
    ],
)
def test_max_children_reads_cgroup_v1(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    quota: str,
    period: str,
    expected: list[str],
) -> None:
    (tmp_path / "quota").write_text(quota + "\n")
    (tmp_path / "period").write_text(period + "\n")
    monkeypatch.setattr(mr, "V1_QUOTA", tmp_path / "quota")
    monkeypatch.setattr(mr, "V1_PERIOD", tmp_path / "period")
    assert mr.max_children() == expected


def test_max_children_does_not_fall_back_from_a_malformed_cgroup_v2_file(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "cpu.max").write_text("max 100000 5\n")
    (tmp_path / "quota").write_text("200000\n")
    (tmp_path / "period").write_text("100000\n")
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "cpu.max")
    monkeypatch.setattr(mr, "V1_QUOTA", tmp_path / "quota")
    monkeypatch.setattr(mr, "V1_PERIOD", tmp_path / "period")
    assert mr.max_children() == []


def test_max_children_prefers_cgroup_v2(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "cpu.max").write_text("100000 100000\n")
    (tmp_path / "quota").write_text("300000\n")
    (tmp_path / "period").write_text("100000\n")
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "cpu.max")
    monkeypatch.setattr(mr, "V1_QUOTA", tmp_path / "quota")
    monkeypatch.setattr(mr, "V1_PERIOD", tmp_path / "period")
    assert mr.max_children() == ["--max-children", "1"]


@pytest.mark.parametrize("children", [0, -1])
def test_main_caps_the_workers_at_the_cpu_quota(
    fake_mutmut: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    children: int,
) -> None:
    (tmp_path / "cpu.max").write_text("300000 100000\n")
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "cpu.max")
    assert mr.main(["report", "log", str(children)]) == 1
    assert fake_mutmut[0] == ["run", "--max-children", "3"]
    assert Path("log").read_text() == (
        "mutmut_report: full: no change set\n"
        "mutmut_report: --max-children 3 (cgroup CPU quota)\n"
    )
    assert capsys.readouterr().err == (
        "mutmut_report: --max-children 3 (cgroup CPU quota)\n"
        "mutmut_report: not cacheable: interrupted\n"
        "mutmut_report: full: no change set\n"
        "mutmut_report: --max-children 3 (cgroup CPU quota)\n"
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
        "skipped=0\ninterrupted=1\nscope=full\n"
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
        "skipped=7\ninterrupted=1\nscope=full\n"
        "mutant.survived=tools.a.x__mutmut_2\n"
        "mutant.no_tests=tools.a.y__mutmut_1\n"
        "mutant.not_checked=tools.a.y__mutmut_2\n"
        "mutant.timeout=tools.a.y__mutmut_3\n"
        "mutant.suspicious=tools.a.y__mutmut_4\n"
        "mutant.segfault=tools.a.y__mutmut_5\n"
        "mutant.skipped=tools.a.y__mutmut_6\n"
        "mutant.caught_by_type_check=tools.a.y__mutmut_7\n"
        "mutant.survived=tools.b: odd.x__mutmut_1\n"
        "mutant.something_else=tools.a.z__mutmut_1\n"
    )


def test_report_counts_type_check_rejects_as_skipped_not_killed() -> None:
    stats: dict[str, object] = {"total": 2, "killed": 1, "caught_by_type_check": 1}
    lines = mr.report(stats, "    m__mutmut_2: caught by type check\n").splitlines()
    assert "killed=1" in lines
    assert "skipped=1" in lines
    assert "mutant.caught_by_type_check=m__mutmut_2" in lines


def test_report_counts_missing_stats_as_zero() -> None:
    assert mr.report({}, "").splitlines()[:9] == [
        "total=0",
        "killed=0",
        "lived=0",
        "not_covered=0",
        "timeout=0",
        "errored=0",
        "skipped=0",
        "interrupted=0",
        "scope=full",
    ]


def test_report_of_a_clean_run() -> None:
    assert mr.report(ALL_KILLED, "    m__mutmut_1: killed\n").endswith(
        "skipped=1\ninterrupted=0\nscope=full\n",
    )


@pytest.mark.parametrize("argv", [[], ["one"], ["a", "b"], ["a", "b", "c", "d"]])
def test_main_needs_a_report_and_a_log(
    argv: list[str],
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Calling mutmut would raise, so a usage error must stop before it.
    monkeypatch.setattr(mr, "mutmut", None)
    assert mr.main(argv) == 2
    assert (
        capsys.readouterr().err == "usage: mutmut_report.py REPORT LOG MAX_CHILDREN "
        "[CHANGES PREFIX [SOURCE_PATH ...]]\n"
    )


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
    capsys: pytest.CaptureFixture[str],
) -> None:
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(json.dumps(ALL_KILLED | {"survived": 1, "total": 5}))
    Path("log").write_text("stale")
    Path("pyproject.toml").write_text("[tool.mutmut]\nsource_paths = []\n")
    assert mr.main(["report", "log", "0"]) == 0
    assert fake_mutmut == [["run"], ["export-cicd-stats"], ["results", "--all", "true"]]
    assert Path("pyproject.toml").read_text() == (
        "[tool.mutmut]\nuse_git_change_detection = false\nsource_paths = []\n"
    )
    assert Path("log").read_text() == (
        "mutmut_report: full: no change set\n"
        "mutmut_report: no --max-children "
        "(no cgroup CPU quota below the host's CPUs)\n"
    )
    assert Path("report").read_text().splitlines() == [
        "total=5",
        "killed=3",
        "lived=1",
        "not_covered=0",
        "timeout=0",
        "errored=0",
        "skipped=1",
        "interrupted=0",
        "scope=full",
        "mutant.survived=m__mutmut_1",
    ]
    assert capsys.readouterr().err == (
        "mutmut_report: no --max-children (no cgroup CPU quota below the host's CPUs)\n"
    )


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
    assert mr.main(["report", "log", "0"]) == 1
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
    ("counts", "cap", "expected"),
    [
        ({}, 10, []),
        ({"total": "100", "timeout": "5"}, 10, []),
        ({"total": "100", "timeout": "10"}, 10, []),
        ({"total": "100", "timeout": "11"}, 10, ["11 timeouts of 100, above 10%"]),
        ({"timeout": "2"}, 10, ["2 timeouts of 0, above 10%"]),
        ({"total": "100", "timeout": "1"}, 0, ["1 timeouts of 100, above 0%"]),
        ({"total": "100"}, 0, []),
        ({"total": "4", "timeout": "4"}, 100, []),
        ({"errored": "1", "total": "100", "timeout": "1"}, 10, ["errored"]),
        ({"interrupted": "1", "lived": "3"}, 10, ["interrupted"]),
        (
            {"errored": "1", "total": "10", "timeout": "5"},
            10,
            ["errored", "5 timeouts of 10, above 10%"],
        ),
    ],
)
def test_unstable(counts: dict[str, str], cap: int, expected: list[str]) -> None:
    keys = ["total", *mr.OUTCOMES, "interrupted"]
    base = dict.fromkeys(keys, "0") | counts
    text = "".join(f"{key}={value}\n" for key, value in base.items())
    assert mr.unstable(text + "mutant.survived=a=b\n", cap) == expected


def test_unstable_flags_a_mutant_never_checked() -> None:
    keys = ["total", *mr.OUTCOMES, "interrupted"]
    text = "".join(f"{key}=0\n" for key in keys)
    assert mr.unstable(text + "mutant.not_checked=a.x_f__mutmut_1\n", 10) == [
        "not_checked",
    ]


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, None),
        ("", None),
        ("ten", None),
        ("-1", None),
        ("1.5", None),
        ("101", None),
        ("0", 0),
        ("10", 10),
        ("100", 100),
    ],
)
def test_timeout_cap(
    monkeypatch: pytest.MonkeyPatch, value: str | None, expected: int | None
) -> None:
    if value is None:
        monkeypatch.delenv(mr.MAX_TIMEOUT_ENV)
    else:
        monkeypatch.setenv(mr.MAX_TIMEOUT_ENV, value)
    assert mr.timeout_cap() == expected


@pytest.mark.parametrize("value", [None, "", "lots", "101"])
def test_main_needs_the_timeout_cap(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    value: str | None,
) -> None:
    monkeypatch.chdir(tmp_path)
    if value is None:
        monkeypatch.delenv(mr.MAX_TIMEOUT_ENV)
    else:
        monkeypatch.setenv(mr.MAX_TIMEOUT_ENV, value)
    assert mr.main(["report", "log", "0"]) == 2
    assert capsys.readouterr().err == (
        "mutmut_report: MUTATION_MAX_TIMEOUT_PERCENT must be 0 to 100\n"
    )
    assert not Path("report").exists()
    assert not Path("log").exists()


@pytest.mark.parametrize(
    "case",  # timeouts, total, cap in percent, exit status
    [
        (5, 100, "10", 0),
        (10, 100, "10", 0),
        (11, 100, "10", 1),
        (1, 100, "0", 1),
        (100, 100, "100", 0),
    ],
)
def test_main_fails_timeouts_above_the_cap_after_writing_the_report(
    fake_mutmut: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    case: tuple[int, int, str, int],
) -> None:
    timeout, total, cap, code = case
    monkeypatch.setenv(mr.MAX_TIMEOUT_ENV, cap)
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(
        json.dumps(
            ALL_KILLED
            | {"total": total, "killed": total - timeout, "skipped": 0}
            | {"timeout": timeout}
        )
    )
    Path("pyproject.toml").write_text("")
    assert mr.main(["report", "log", "0"]) == code
    assert len(fake_mutmut) == 3
    lines = Path("report").read_text().splitlines()
    assert lines[:2] == [f"total={total}", f"killed={total - timeout}"]
    assert f"timeout={timeout}" in lines
    message = f"mutmut_report: not cacheable: {timeout} timeouts of {total}, above"
    assert (message in capsys.readouterr().err) is bool(code)


def test_main_fails_an_unstable_run_and_shows_the_log(
    fake_mutmut: list[list[str]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    # One timeout of 100 is within the cap: only the errored mutants are named.
    stats.write_text(
        json.dumps(ALL_KILLED | {"total": 100, "timeout": 1, "segfault": 2})
    )
    Path("pyproject.toml").write_text("")
    assert mr.main(["report", "log", "0"]) == 1
    assert len(fake_mutmut) == 3
    assert capsys.readouterr().err == (
        "mutmut_report: no --max-children (no cgroup CPU quota below the host's CPUs)\n"
        "mutmut_report: not cacheable: errored\n"
        "mutmut_report: full: no change set\n"
        "mutmut_report: no --max-children "
        "(no cgroup CPU quota below the host's CPUs)\n"
    )


def test_main_lists_every_unstable_verdict_in_the_message(
    fake_mutmut: list[list[str]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(
        json.dumps(ALL_KILLED | {"segfault": 1, "check_was_interrupted_by_user": True})
    )
    Path("pyproject.toml").write_text("")
    assert mr.main(["report", "log", "0"]) == 1
    assert len(fake_mutmut) == 3
    assert "mutmut_report: not cacheable: errored, interrupted\n" in (
        capsys.readouterr().err
    )


@pytest.mark.parametrize(
    ("text", "paths", "expected"),
    [
        (
            '[tool.mutmut]\nsource_paths = ["old"] # keep\ndo_not_mutate = ["gen/*"]\n',
            ["src", "lib"],
            (
                "[tool.mutmut]\n"
                'source_paths = ["src", "lib"] # keep\n'
                'do_not_mutate = ["gen/*"]\n'
            ),
        ),
        (
            '[tool.mutmut]\ndo_not_mutate = ["gen/*"]\n[tool.other]\nx = 1\n',
            ["src"],
            (
                "[tool.mutmut]\n"
                'source_paths = ["src"]\n'
                'do_not_mutate = ["gen/*"]\n'
                "[tool.other]\n"
                "x = 1\n"
            ),
        ),
        (
            '[project]\nname = "unit"\n',
            ["src"],
            '[project]\nname = "unit"\n\n[tool.mutmut]\nsource_paths = ["src"]\n',
        ),
        ('[tool.mutmut]\nsource_paths = ["old"]\n', [], None),
        ('[project]\nname = "unit"\n', [], None),
        (
            (
                "[tool.mutmut]\n"
                "source_paths = [\n"
                '  "old]", # ]\n'
                '  "more",\n'
                "]\n"
                "do_not_mutate = []\n"
            ),
            ["src"],
            '[tool.mutmut]\nsource_paths = ["src"]\ndo_not_mutate = []\n',
        ),
        (
            (
                "[tool.mutmut] # keep\n"
                '"source_paths" = ["old"]\n'
                "[tool.other]\n"
                'source_paths = ["other"]\n'
            ),
            ["src"],
            (
                "[tool.mutmut] # keep\n"
                'source_paths = ["src"]\n'
                "[tool.other]\n"
                'source_paths = ["other"]\n'
            ),
        ),
        ("[tool.mutmut]", ["src"], '[tool.mutmut]\nsource_paths = ["src"]'),
        (
            (
                "[tool.mutmut]\ndo_not_mutate = []\n"
                '  [tool.other]\nsource_paths = ["other"]\n'
            ),
            ["src"],
            (
                '[tool.mutmut]\nsource_paths = ["src"]\ndo_not_mutate = []\n'
                '  [tool.other]\nsource_paths = ["other"]\n'
            ),
        ),
    ],
)
def test_rewrite_source_paths(
    tmp_path: Path,
    text: str,
    paths: list[str],
    expected: str | None,
) -> None:
    path = tmp_path / "pyproject.toml"
    path.write_text(text)
    mr.rewrite_source_paths(path, paths)
    assert path.read_text() == (text if expected is None else expected)


def test_rewrite_source_paths_quotes_paths(tmp_path: Path) -> None:
    path = tmp_path / "pyproject.toml"
    path.write_text("[tool.mutmut]\n")
    paths = ['src/quote"', "src/with space", "src/\\backslash", "src/🚀"]
    mr.rewrite_source_paths(path, paths)
    assert mr.mutmut_paths(path) == (paths, [])


def test_rewrite_source_paths_at_the_end_of_a_long_table(tmp_path: Path) -> None:
    path = tmp_path / "pyproject.toml"
    before = "[tool.mutmut]\n" + "# keep this comment\n" * 12
    after = "\n[tool.other]\nx = 1\n"
    path.write_text(before + 'source_paths = ["old"]' + after)
    mr.rewrite_source_paths(path, ["src"])
    assert path.read_text() == before + 'source_paths = ["src"]' + after


@pytest.mark.parametrize("children", [0, 7])
def test_main_rewrites_paths_before_running(
    fake_mutmut: list[list[str]],
    children: int,
) -> None:
    Path("pyproject.toml").write_text('[tool.mutmut]\nsource_paths = ["old"]\n')
    assert mr.main(["report", "log", str(children), "", "unit", "src"]) == 1
    assert mr.mutmut_paths(Path("pyproject.toml")) == (["src"], [])
    cap = ["--max-children", str(children)] if children else []
    assert fake_mutmut[0] == ["run", *cap]


@pytest.mark.parametrize("children", [1, 2, 20])
def test_main_overrides_the_worker_cap(
    fake_mutmut: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    children: int,
) -> None:
    # An explicit cap must bypass quota detection, even above the host's CPUs.
    monkeypatch.setattr(mr, "max_children", None)
    stats = Path("mutants/mutmut-cicd-stats.json")
    stats.parent.mkdir()
    stats.write_text(json.dumps(ALL_KILLED))
    assert mr.main(["report", "log", str(children)]) == 0
    assert fake_mutmut[0] == ["run", "--max-children", str(children)]
    message = (
        f"mutmut_report: --max-children {children} (set by --mutmut_max_children)\n"
    )
    assert capsys.readouterr().err == message
    assert Path("log").read_text() == "mutmut_report: full: no change set\n" + message


def test_main_rejects_a_noninteger_worker_cap(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.chdir(tmp_path)
    assert mr.main(["report", "log", "two"]) == 2
    assert capsys.readouterr().err == "mutmut_report: MAX_CHILDREN must be an integer\n"
    assert not Path("report").exists()
    assert not Path("log").exists()
