# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from runtime.private import launch


class Executed(Exception):  # noqa: N818 - a sentinel, not an error.
    """Raised in place of os.execv so a test can see what would run."""


@pytest.fixture(autouse=True)
def no_real_exec(monkeypatch: pytest.MonkeyPatch) -> None:
    # A test that reaches os.execv by mistake fails instead of replacing the
    # test process (which, under mutmut, can exit 0 and pass a mutant).
    monkeypatch.setattr(launch.os, "execv", None)


@pytest.fixture
def executed(monkeypatch: pytest.MonkeyPatch) -> list[list[str]]:
    calls: list[list[str]] = []

    def fake(argv: list[str]) -> None:
        calls.append(argv)
        raise Executed

    monkeypatch.setattr(launch, "execute", fake)
    return calls


def no_entry_points(**_: str) -> list[SimpleNamespace]:
    return []


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


@pytest.mark.parametrize(
    ("name", "text", "expected"),
    [
        ("a.py", "", True),
        ("a.pyi", "", True),
        ("script", "#!/usr/bin/env python3\n", True),
        ("script", "#!/usr/bin/python3.15 -I\n", True),
        ("script", "#!/usr/bin/env -S uv run --script\n", True),
        ("script", "#!/bin/sh\n", False),
        ("script", "#!/usr/bin/env pythonista\n", False),
        ("script", "# python\n", False),
        ("notes.txt", "", False),
        ("script.pyc", "", False),
    ],
)
def test_is_python(tmp_path: Path, name: str, text: str, expected: bool) -> None:
    assert launch.is_python(write(tmp_path / name, text)) is expected


def test_select_finds_sorted_relative_python_files(tmp_path: Path) -> None:
    write(tmp_path / "b.py", "")
    write(tmp_path / "a" / "c.py", "")
    write(tmp_path / "tools" / "run", "#!/usr/bin/env python3\n")
    write(tmp_path / "README.md", "# python\n")
    write(tmp_path / ".git" / "hooks" / "x.py", "")
    (tmp_path / "empty.py").mkdir()
    assert launch.select(tmp_path, []) == ["a/c.py", "b.py", "tools/run"]


def test_select_skips_excluded_paths(tmp_path: Path) -> None:
    write(tmp_path / "keep.py", "")
    write(tmp_path / "tools" / "test_x.py", "")
    write(tmp_path / "skip.py", "")
    write(tmp_path / "zz.py", "")
    assert launch.select(tmp_path, ["**/test_*.py", "skip.py"]) == ["keep.py", "zz.py"]


def test_expand_replaces_environment_references(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("XML_OUTPUT_FILE", "/out/test.xml")
    monkeypatch.delenv("UNSET_FOR_TEST", raising=False)
    assert (
        launch.expand("--junitxml={env:XML_OUTPUT_FILE}") == "--junitxml=/out/test.xml"
    )
    assert launch.expand("a{env:UNSET_FOR_TEST}b") == "ab"
    assert launch.expand("{env:}") == "{env:}"


def test_parse_reads_every_option() -> None:
    options, command = launch.parse(
        [
            "--select",
            "--filter",
            "--allow-empty",
            "--exclude",
            "a",
            "--exclude",
            "b",
            "--chdir",
            "cli",
            "--",
            "ruff",
            "check",
            "--",
        ],
    )
    assert options == launch.Options(
        select=True,
        filter=True,
        allow_empty=True,
        exclude=["a", "b"],
        chdir="cli",
    )
    assert command == ["ruff", "check", "--"]


def test_parse_defaults() -> None:
    assert launch.parse(["--", "pytest"]) == (launch.Options(), ["pytest"])


@pytest.mark.parametrize(
    ("argv", "message"),
    [
        (["--bogus", "--", "x"], "unexpected argument '--bogus'"),
        (["--exclude"], "unexpected argument '--exclude'"),
        (["--chdir"], "unexpected argument '--chdir'"),
        (["--"], "no tool given"),
        ([], "no tool given"),
        (["--select"], "no tool given"),
    ],
)
def test_parse_rejects_bad_usage(argv: list[str], message: str) -> None:
    with pytest.raises(launch.UsageError, match=f"^{message}$"):
        launch.parse(argv)


def test_execute_replaces_the_process(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, list[str]]] = []

    def fake_execv(path: str, argv: list[str]) -> None:
        calls.append((path, argv))
        raise Executed

    monkeypatch.setattr(os, "execv", fake_execv)
    monkeypatch.setattr(launch, "WINDOWS", False)
    with pytest.raises(Executed):
        launch.execute(["/bin/tool", "a"])
    assert calls == [("/bin/tool", ["/bin/tool", "a"])]


def test_execute_on_windows_waits_and_passes_the_status_on(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(argv: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
        assert check is False
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 3)

    monkeypatch.setattr(launch, "WINDOWS", True)
    monkeypatch.setattr(launch.subprocess, "run", fake_run)
    with pytest.raises(SystemExit) as exited:
        launch.execute(["C:/env/tool.exe", "a"])
    assert exited.value.code == 3
    assert calls == [["C:/env/tool.exe", "a"]]


def test_run_python_execs_the_interpreter(executed: list[list[str]]) -> None:
    with pytest.raises(Executed):
        launch.run("python", ["-c", "pass"])
    assert executed == [[sys.executable, "-c", "pass"]]


def test_run_uv_execs_the_pinned_uv(
    executed: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("TBHB_PYTHON_UV", "/env/uv")
    with pytest.raises(Executed):
        launch.run("uv", ["export"])
    assert executed == [["/env/uv", "export"]]


def entry_point(result: object, seen: list[list[str]]) -> SimpleNamespace:
    def main() -> object:
        seen.append(list(sys.argv))
        return result

    return SimpleNamespace(load=lambda: main)


@pytest.mark.parametrize(
    ("result", "status"),
    [(None, 0), (0, 0), (3, 3), ("failed", 1)],
)
def test_run_calls_a_console_script(
    monkeypatch: pytest.MonkeyPatch,
    result: object,
    status: int,
) -> None:
    seen: list[list[str]] = []
    groups: list[tuple[str, str]] = []

    def fake_entry_points(*, group: str, name: str) -> list[SimpleNamespace]:
        groups.append((group, name))
        return [entry_point(result, seen)]

    monkeypatch.setattr(launch, "entry_points", fake_entry_points)
    monkeypatch.setattr(sys, "argv", ["launch.py"])
    assert launch.run("pytest", ["-q"]) == status
    assert seen == [["pytest", "-q"]]
    assert groups == [("console_scripts", "pytest")]


def test_run_execs_a_binary_from_the_environment(
    executed: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(launch, "entry_points", no_entry_points)
    monkeypatch.setenv("TBHB_PYTHON_BIN", str(tmp_path))
    write(tmp_path / "ruff", "")
    with pytest.raises(Executed):
        launch.run("ruff", ["check"])
    assert executed == [[str(tmp_path / "ruff"), "check"]]


@pytest.mark.parametrize("windows", [True, False])
def test_run_finds_an_exe_only_on_windows(
    executed: list[list[str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    windows: bool,
) -> None:
    monkeypatch.setattr(launch, "entry_points", no_entry_points)
    monkeypatch.setattr(launch, "WINDOWS", windows)
    monkeypatch.setenv("TBHB_PYTHON_BIN", str(tmp_path))
    write(tmp_path / "ruff.exe", "")
    if windows:
        with pytest.raises(Executed):
            launch.run("ruff", ["check"])
        assert executed == [[str(tmp_path / "ruff.exe"), "check"]]
    else:
        with pytest.raises(launch.UsageError):
            launch.run("ruff", ["check"])


def test_run_rejects_an_unknown_tool(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(launch, "entry_points", no_entry_points)
    monkeypatch.setenv("TBHB_PYTHON_BIN", str(tmp_path))
    (tmp_path / "dir").mkdir()
    for tool in ("missing", "dir"):
        message = f"^'{tool}' is neither a console script nor in the environment's bin$"
        with pytest.raises(launch.UsageError, match=message):
            launch.run(tool, [])


@pytest.fixture
def recorded(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, list[str], str]]:
    calls: list[tuple[str, list[str], str]] = []

    def fake_run(tool: str, args: list[str]) -> int:
        calls.append((tool, args, Path.cwd().name))
        return 7

    monkeypatch.setattr(launch, "run", fake_run)
    return calls


def test_main_reports_bad_usage(capsys: pytest.CaptureFixture[str]) -> None:
    assert launch.main(["--bogus"]) == 2
    assert capsys.readouterr().err == "launch.py: unexpected argument '--bogus'\n"


def test_main_runs_the_tool_with_expanded_args(
    recorded: list[tuple[str, list[str], str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("OUT", "x.xml")
    assert launch.main(["--", "pytest", "--junitxml={env:OUT}"]) == 7
    assert recorded == [("pytest", ["--junitxml=x.xml"], tmp_path.name)]


def test_main_selects_python_files_from_the_run_directory(
    recorded: list[tuple[str, list[str], str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    write(tmp_path / "top.py", "")
    write(tmp_path / "cli" / "a.py", "")
    write(tmp_path / "cli" / "test_a.py", "")
    monkeypatch.chdir(tmp_path)
    argv = ["--select", "--exclude", "test_*", "--chdir", "cli", "--", "ruff", "check"]
    assert launch.main(argv) == 7
    assert recorded == [("ruff", ["check", "a.py"], "cli")]
    assert capsys.readouterr().err == "launch.py: 1 Python files\n"


def test_main_fails_when_selection_finds_nothing(
    recorded: list[tuple[str, list[str], str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.chdir(tmp_path)
    assert launch.main(["--select", "--", "ruff"]) == 1
    assert recorded == []
    assert capsys.readouterr().err == (
        "launch.py: no Python files, so nothing was checked\n"
    )


def test_main_allows_an_empty_selection_when_asked(
    recorded: list[tuple[str, list[str], str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.chdir(tmp_path)
    assert launch.main(["--select", "--allow-empty", "--", "ruff"]) == 0
    assert recorded == []
    assert capsys.readouterr().err == ""


def test_main_filters_the_arguments_to_python_files(
    recorded: list[tuple[str, list[str], str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    write(tmp_path / "a.py", "")
    write(tmp_path / "notes.md", "")
    write(tmp_path / "run", "#!/usr/bin/env python3\n")
    monkeypatch.chdir(tmp_path)
    argv = ["--filter", "--", "ruff", "format", "a.py", "notes.md", "run", "gone.py"]
    assert launch.main(argv) == 7
    assert recorded == [("ruff", ["format", "a.py", "run", "gone.py"], tmp_path.name)]


@pytest.mark.parametrize("case", [([], 1), (["--allow-empty"], 0)])
def test_main_filtering_to_nothing(
    recorded: list[tuple[str, list[str], str]],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    case: tuple[list[str], int],
) -> None:
    flags, code = case
    write(tmp_path / "notes.md", "")
    monkeypatch.chdir(tmp_path)
    assert (
        launch.main(["--filter", *flags, "--", "ruff", "--check", "notes.md"]) == code
    )
    assert recorded == []
    expected = "launch.py: no Python files, so nothing was checked\n" if code else ""
    assert capsys.readouterr().err == expected


def test_main_reports_an_unknown_tool(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(launch, "entry_points", no_entry_points)
    monkeypatch.setenv("TBHB_PYTHON_BIN", str(tmp_path))
    assert launch.main(["--", "nope"]) == 2
    assert capsys.readouterr().err == (
        "launch.py: 'nope' is neither a console script nor in the environment's bin\n"
    )
