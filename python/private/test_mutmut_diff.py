# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import re
import subprocess
from pathlib import Path, PurePosixPath

import pytest

from private import mutmut_report as mr

SOURCE = '''\
"""Doc."""

import os

LIMIT = 3


def plain(a):
    return a + 1


@decorated
@twice
def wrapped(a):
    def inner():
        return a
    return inner


async def waits():
    return 1


class Box:
    size = 2

    def grow(self):
        return self.size * 2

    async def shrink(self):
        return 0


if os:
    pass
'''


def changes_file(tmp_path: Path, files: object, version: object = 1) -> Path:
    path = tmp_path / "changes.json"
    path.write_text(json.dumps({"version": version, "files": files}))
    return path


def test_table_and_array() -> None:
    assert mr.table({"a": 1}) == {"a": 1}
    assert mr.table([]) == {}
    assert mr.array([1]) == [1]
    assert mr.array({}) is None


def test_load_changes(tmp_path: Path) -> None:
    path = changes_file(
        tmp_path,
        {"a.py": [[1, 2], [5, 5]], "b.bin": [], "c.py": "added", "d.py": "deleted"},
    )
    assert mr.load_changes(path) == {
        "a.py": [(1, 2), (5, 5)],
        "b.bin": [],
        "c.py": "added",
        "d.py": "deleted",
    }
    assert mr.load_changes(changes_file(tmp_path, {})) == {}


@pytest.mark.parametrize(
    ("content", "message"),
    [
        ("", "not JSON: Expecting value"),
        ("{", "not JSON: Expecting property name enclosed in double quotes"),
        ("[]", "not a version 1 change set"),
        ('{"version": 2, "files": {}}', "not a version 1 change set"),
        ('{"version": 1, "files": []}', "`files` is not an object"),
        ('{"version": 1, "files": {"a": 1}}', "a: neither ranges nor added or deleted"),
        ('{"version": 1, "files": {"a": "moved"}}', "a: neither ranges nor"),
        ('{"version": 1, "files": {"a": [[2, 1]]}}', r"a: bad range \[2, 1\]"),
        ('{"version": 1, "files": {"a": [[0, 1]]}}', r"a: bad range \[0, 1\]"),
        ('{"version": 1, "files": {"a": [[1]]}}', r"a: bad range \[1\]"),
        ('{"version": 1, "files": {"a": [[1, 2, 3]]}}', r"a: bad range \[1, 2, 3\]"),
        ('{"version": 1, "files": {"a": [[1, "2"]]}}', r"a: bad range \[1, '2'\]"),
        ('{"version": 1, "files": {"a": [[true, 2]]}}', r"a: bad range \[True, 2\]"),
        ('{"version": 1, "files": {"a": [3]}}', r"a: bad range 3"),
    ],
)
def test_load_changes_rejects(tmp_path: Path, content: str, message: str) -> None:
    path = tmp_path / "changes.json"
    path.write_text(content)
    with pytest.raises(mr.ChangesError, match=f"^{re.escape(str(path))}: {message}"):
        mr.load_changes(path)


def test_line_range_accepts_one_line() -> None:
    assert mr.line_range(Path("c"), "a", [4, 4]) == (4, 4)


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("tests/test_a.py", True),
        ("a_test.py", True),
        ("pkg/conftest.py", True),
        ("fixtures/x.py", True),
        ("src/pkg/a.py", False),
        ("src/pkg/testing.py", False),
    ],
)
def test_is_test(name: str, expected: bool) -> None:
    assert mr.is_test(PurePosixPath(name), ["fixtures/*"]) is expected


def test_functions() -> None:
    assert mr.functions(SOURCE) == [
        ("x_plain", 8, 9),
        ("x_wrapped", 12, 17),
        ("x_waits", 20, 21),
        ("xǁBoxǁgrow", 27, 28),
        ("xǁBoxǁshrink", 30, 31),
    ]


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("src/pkg/mod.py", "pkg.mod"),
        ("source/pkg/mod.py", "pkg.mod"),
        ("pkg/__init__.py", "pkg"),
        ("tools/a.py", "tools.a"),
        ("srcx/a.py", "srcx.a"),
    ],
)
def test_module_name(name: str, expected: str) -> None:
    assert mr.module_name(PurePosixPath(name)) == expected


def test_under() -> None:
    assert mr.under(PurePosixPath("src/a.py"), ["lib", "src"])
    assert not mr.under(PurePosixPath("srcx/a.py"), ["src"])


@pytest.fixture
def unit(tmp_path: Path) -> Path:
    (tmp_path / "src" / "pkg").mkdir(parents=True)
    (tmp_path / "src" / "pkg" / "mod.py").write_text(SOURCE)
    (tmp_path / "src" / "pkg" / "other.py").write_text("def f():\n    return 1\n")
    return tmp_path


def choose_in(unit: Path, files: dict[str, mr.Change]) -> mr.Selection:
    return mr.select(files, "cli", unit, ["src"], ["src/gen/*"])


def test_select_picks_the_changed_functions(unit: Path) -> None:
    selection = choose_in(
        unit,
        {
            "cli/src/pkg/mod.py": [(9, 9), (14, 14), (28, 30), (8, 9)],
            "cli/src/pkg/other.py": [(2, 2)],
            "cli/src/pkg/binary.py": [],
        },
    )
    assert selection == mr.Selection(
        globs=[
            "pkg.mod.x_plain__mutmut_*",
            "pkg.mod.x_wrapped__mutmut_*",
            "pkg.mod.xǁBoxǁgrow__mutmut_*",
            "pkg.mod.xǁBoxǁshrink__mutmut_*",
            "pkg.other.x_f__mutmut_*",
        ],
    )


def test_select_from_the_tree_root(unit: Path) -> None:
    selection = mr.select({"src/pkg/other.py": [(1, 1)]}, "", unit, ["src"], [])
    assert selection.globs == ["pkg.other.x_f__mutmut_*"]


def test_select_of_nothing(unit: Path) -> None:
    assert choose_in(unit, {}) == mr.Selection()


@pytest.mark.parametrize(
    ("name", "change", "reason"),
    [
        ("core/lib.py", [(1, 1)], "core/lib.py, outside the unit, changed"),
        ("pyproject.toml", [(1, 1)], "pyproject.toml, outside the unit, changed"),
        ("cli/src/pkg/new.py", "added", "src/pkg/new.py was added"),
        ("cli/src/pkg/gone.py", "deleted", "src/pkg/gone.py was deleted"),
        ("cli/tests/test_mod.py", [(1, 1)], "tests/test_mod.py is a test file"),
        ("cli/src/gen/x.py", [(1, 1)], "src/gen/x.py is a test file"),
        (
            "cli/pyproject.toml",
            [(1, 1)],
            "pyproject.toml is not Python source under the mutated paths",
        ),
        (
            "cli/src/pkg/data.json",
            [],
            "src/pkg/data.json is not Python source under the mutated paths",
        ),
        (
            "cli/tools/x.py",
            [(1, 1)],
            "tools/x.py is not Python source under the mutated paths",
        ),
        (
            "cli/src/pkg/mod.py",
            [(9, 9), (5, 5)],
            "src/pkg/mod.py:5-5 changes code outside any function",
        ),
        (
            "cli/src/pkg/mod.py",
            [(24, 25)],
            "src/pkg/mod.py:24-25 changes code outside any function",
        ),
    ],
)
def test_select_falls_back_to_full(
    unit: Path, name: str, change: mr.Change, reason: str
) -> None:
    files: dict[str, mr.Change] = {"cli/src/pkg/other.py": [(1, 1)], name: change}
    assert choose_in(unit, files) == mr.Selection(full=True, reason=reason)


RESULTS = """\
    pkg.mod.x_plain__mutmut_1: killed
    pkg.mod.x_plain__mutmut_2: survived
    pkg.mod.x_plain__mutmut_3: caught by type check
    pkg.mod.x_wrapped__mutmut_1: no tests
    pkg.mod.x_wrapped__mutmut_2: timeout
    pkg.mod.x_wrapped__mutmut_3: suspicious
    pkg.mod.x_wrapped__mutmut_4: segfault
    pkg.mod.x_wrapped__mutmut_5: skipped
    pkg.mod.x_wrapped__mutmut_6: not checked
    pkg.mod.x_other__mutmut_1: survived
    pkg.mod.x_other__mutmut_2: not checked
noise
"""


def test_results_by_name() -> None:
    assert mr.results_by_name("    a.b: killed\nnoise\n    c: no tests\n") == {
        "a.b": "killed",
        "c": "no tests",
    }


def test_diff_report_counts_only_the_selected_mutants() -> None:
    selection = mr.Selection(
        globs=[
            "pkg.mod.x_plain__mutmut_*",
            "pkg.mod.x_wrapped__mutmut_*",
            "pkg.x_none__mutmut_*",
        ],
    )
    report = mr.diff_report(mr.results_by_name(RESULTS), selection)
    assert report.splitlines() == [
        "total=9",
        "killed=1",
        "lived=1",
        "not_covered=1",
        "timeout=1",
        "errored=2",
        "skipped=2",
        "interrupted=0",
        "scope=diff",
        "selected=9",
        "changed_units=2",
        "mutant.survived=pkg.mod.x_plain__mutmut_2",
        "mutant.caught_by_type_check=pkg.mod.x_plain__mutmut_3",
        "mutant.no_tests=pkg.mod.x_wrapped__mutmut_1",
        "mutant.timeout=pkg.mod.x_wrapped__mutmut_2",
        "mutant.suspicious=pkg.mod.x_wrapped__mutmut_3",
        "mutant.segfault=pkg.mod.x_wrapped__mutmut_4",
        "mutant.skipped=pkg.mod.x_wrapped__mutmut_5",
        "mutant.unmapped=pkg.mod.x_wrapped__mutmut_6",
        "mutant.unmapped=pkg.mod.x_other__mutmut_1",
    ]


def test_diff_report_of_nothing_selected() -> None:
    assert mr.diff_report({}, mr.Selection()).splitlines() == [
        "total=0",
        "killed=0",
        "lived=0",
        "not_covered=0",
        "timeout=0",
        "errored=0",
        "skipped=0",
        "interrupted=0",
        "scope=diff",
        "selected=0",
        "changed_units=0",
    ]


def test_mutmut_paths(tmp_path: Path) -> None:
    path = tmp_path / "pyproject.toml"
    path.write_text(
        '[tool.mutmut]\nsource_paths = ["src"]\ndo_not_mutate = ["src/gen/*"]\n'
    )
    assert mr.mutmut_paths(path) == (["src"], ["src/gen/*"])
    path.write_text("[tool.other]\n")
    assert mr.mutmut_paths(path) == ([], [])


def test_choose(unit: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(unit)
    (unit / "pyproject.toml").write_text("")
    empty = changes_file(unit, {})
    assert mr.choose(empty, "cli") == mr.Selection()
    changes = changes_file(unit, {"cli/src/pkg/other.py": [[1, 1]]})
    assert mr.choose(changes, "cli") == mr.Selection(
        full=True, reason="[tool.mutmut] sets no source_paths"
    )
    (unit / "pyproject.toml").write_text(
        '[tool.mutmut]\nsource_paths = ["src"]\ndo_not_mutate = ["src/pkg/other.py"]\n'
    )
    assert mr.choose(changes, "cli").reason == "src/pkg/other.py is a test file"
    (unit / "pyproject.toml").write_text('[tool.mutmut]\nsource_paths = ["src"]\n')
    assert mr.choose(changes, "cli").globs == ["pkg.other.x_f__mutmut_*"]


@pytest.fixture
def runs(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> list[list[str]]:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(mr.os, "cpu_count", lambda: 16)
    for name in ("CPU_MAX", "V1_QUOTA", "V1_PERIOD"):
        monkeypatch.setattr(mr, name, Path("/nonexistent") / name)
    calls: list[list[str]] = []

    def fake(args: list[str], log: Path) -> subprocess.CompletedProcess[str]:
        assert log == Path("log")
        calls.append(args)
        out = "    pkg.other.x_f__mutmut_1: survived\n" if args[0] == "results" else ""
        return subprocess.CompletedProcess(args, 0, out, "")

    monkeypatch.setattr(mr, "mutmut", fake)
    return calls


def test_run_diff(runs: list[list[str]], capsys: pytest.CaptureFixture[str]) -> None:
    selection = mr.Selection(globs=["pkg.other.x_f__mutmut_*"])
    text = mr.run_diff(Path("log"), selection)
    assert runs == [["run", "pkg.other.x_f__mutmut_*"], ["results", "--all", "true"]]
    assert "mutant.survived=pkg.other.x_f__mutmut_1" in text.splitlines()
    assert capsys.readouterr().err == (
        "mutmut_report: no --max-children (no cgroup CPU quota below the host's CPUs)\n"
    )


def test_run_diff_caps_the_workers_at_the_cpu_quota(
    runs: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    (tmp_path / "cpu.max").write_text("200000 100000\n")
    monkeypatch.setattr(mr, "CPU_MAX", tmp_path / "cpu.max")
    mr.run_diff(Path("log"), mr.Selection(globs=["pkg.other.x_f__mutmut_*"]))
    assert runs[0] == ["run", "--max-children", "2", "pkg.other.x_f__mutmut_*"]
    assert capsys.readouterr().err == (
        "mutmut_report: --max-children 2 (cgroup CPU quota)\n"
    )
    assert Path("log").read_text() == (
        "mutmut_report: --max-children 2 (cgroup CPU quota)\n"
    )


def test_run_diff_with_nothing_selected(
    runs: list[list[str]], capsys: pytest.CaptureFixture[str]
) -> None:
    text = mr.run_diff(Path("log"), mr.Selection())
    assert text == mr.diff_report({}, mr.Selection())
    assert text.splitlines()[:2] == ["total=0", "killed=0"]
    assert "selected=0" in text.splitlines()
    assert runs == []
    assert capsys.readouterr().err == ""


def test_main_runs_a_diff(
    unit: Path, runs: list[list[str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(unit)
    (unit / "pyproject.toml").write_text('[tool.mutmut]\nsource_paths = ["src"]\n')
    changes = changes_file(unit, {"cli/src/pkg/other.py": [[2, 2]]})
    assert mr.main(["report", "log", str(changes), "cli"]) == 0
    lines = Path("report").read_text().splitlines()
    assert "scope=diff" in lines
    assert "mutant.survived=pkg.other.x_f__mutmut_1" in lines
    assert Path("log").read_text() == (
        "mutmut_report: diff\n"
        "mutmut_report: no --max-children "
        "(no cgroup CPU quota below the host's CPUs)\n"
    )
    assert runs[0] == ["run", "pkg.other.x_f__mutmut_*"]


def test_main_runs_nothing_for_an_empty_slice(
    unit: Path, runs: list[list[str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(unit)
    assert mr.main(["report", "log", str(changes_file(unit, {})), "cli"]) == 0
    assert "changed_units=0" in Path("report").read_text().splitlines()
    assert runs == []
    assert Path("log").read_text() == "mutmut_report: diff\n"


def test_main_runs_full_when_the_slice_cannot_be_scoped(
    unit: Path, runs: list[list[str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(unit)
    (unit / "pyproject.toml").write_text('[tool.mutmut]\nsource_paths = ["src"]\n')
    changes = changes_file(unit, {"core/lib.py": [[1, 1]]})
    assert mr.main(["report", "log", str(changes), "cli"]) == 1
    assert "scope=full" in Path("report").read_text().splitlines()
    assert (
        Path("log")
        .read_text()
        .startswith("mutmut_report: full: core/lib.py, outside the unit, changed\n")
    )
    assert runs[0] == ["run"]


def test_main_rejects_a_bad_change_set(
    unit: Path,
    runs: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.chdir(unit)
    bad = unit / "bad.json"
    bad.write_text("[]")
    assert mr.main(["report", "log", str(bad), "cli"]) == 2
    assert capsys.readouterr().err == (
        f"mutmut_report: {bad}: not a version 1 change set\n"
    )
    assert runs == []


def test_main_uses_overridden_paths_for_diff_selection(
    unit: Path,
    runs: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    (unit / "pyproject.toml").write_text('[tool.mutmut]\nsource_paths = ["wrong"]\n')
    monkeypatch.chdir(unit)
    changes = changes_file(unit, {"cli/src/pkg/other.py": [[2, 2]]})
    assert mr.main(["report", "log", str(changes), "cli", "src"]) == 0
    assert runs[0] == ["run", "pkg.other.x_f__mutmut_*"]
    assert "scope=diff" in Path("report").read_text().splitlines()
