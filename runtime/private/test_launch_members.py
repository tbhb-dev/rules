# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import base64
import hashlib
import os
import subprocess
import sys
import sysconfig
import zipfile
from pathlib import Path

import pytest

from runtime.private import launch

PYPROJECT = """\
[project]
name = "Demo.Pkg_x"
version = "1.2.3"

[project.scripts]
demo-hello = "demo:main"

[project.gui-scripts]
demo-gui = "demo:gui"

[project.entry-points."demo.plugins"]
one = "demo.one:plugin"
"""


def member(root: Path, text: str = PYPROJECT) -> Path:
    path = root / "m"
    path.mkdir()
    (path / "pyproject.toml").write_text(text)
    return path


def test_normalize() -> None:
    assert launch.normalize("Demo.Pkg-x__y") == "demo_pkg_x_y"


def test_table() -> None:
    assert launch.table({"a": 1}) == {"a": 1}
    assert launch.table([1]) == {}
    assert launch.table(None) == {}


def test_entry_points_text() -> None:
    project: dict[str, object] = {
        "scripts": {"a": "m:a", "b": "m:b"},
        "gui-scripts": {},
        "entry-points": {"x.y": {"p": "m:p"}, "empty": {}, "bad": "no"},
    }
    assert launch.entry_points_text(project) == (
        "[console_scripts]\na = m:a\nb = m:b\n[x.y]\np = m:p\n"
    )
    assert launch.entry_points_text({}) == ""


def test_record_line() -> None:
    digest = base64.urlsafe_b64encode(hashlib.sha256(b"abc").digest()).rstrip(b"=")
    assert launch.record_line("x/y", b"abc") == f"x/y,sha256={digest.decode()},3"


def test_member_wheel(tmp_path: Path) -> None:
    wheel = launch.member_wheel(member(tmp_path), tmp_path)
    assert wheel == tmp_path / "demo_pkg_x-1.2.3-py3-none-any.whl"
    info = "demo_pkg_x-1.2.3.dist-info"
    with zipfile.ZipFile(wheel) as archive:
        assert archive.namelist() == [
            f"{info}/METADATA",
            f"{info}/WHEEL",
            f"{info}/entry_points.txt",
            f"{info}/RECORD",
        ]
        metadata = archive.read(f"{info}/METADATA").decode()
        entries = archive.read(f"{info}/entry_points.txt").decode()
        record = archive.read(f"{info}/RECORD").decode().splitlines()
        wheel_text = archive.read(f"{info}/WHEEL").decode()
    assert metadata == "Metadata-Version: 2.1\nName: Demo.Pkg_x\nVersion: 1.2.3\n"
    assert wheel_text == launch.WHEEL
    assert entries == (
        "[console_scripts]\ndemo-hello = demo:main\n"
        "[gui_scripts]\ndemo-gui = demo:gui\n"
        "[demo.plugins]\none = demo.one:plugin\n"
    )
    assert record[0] == launch.record_line(f"{info}/METADATA", metadata.encode())
    assert record[-1] == f"{info}/RECORD,,"
    assert len(record) == 4


def test_member_wheel_defaults_the_version(tmp_path: Path) -> None:
    path = member(tmp_path, '[project]\nname = "d"\ndynamic = ["version"]\n')
    assert launch.member_wheel(path, tmp_path).name == "d-0-py3-none-any.whl"


@pytest.fixture
def uv_runs(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> list[tuple[list[str], dict[str, str]]]:
    calls: list[tuple[list[str], dict[str, str]]] = []
    codes = [0]

    def fake_run(
        command: list[str], *, env: dict[str, str], check: bool
    ) -> subprocess.CompletedProcess[str]:
        assert check is False
        calls.append((command, env))
        return subprocess.CompletedProcess(command, codes[0])

    monkeypatch.setattr(launch.subprocess, "run", fake_run)
    monkeypatch.setattr(launch, "uv_codes", codes, raising=False)
    monkeypatch.setenv("TBHB_PYTHON_UV", "/env/uv")
    monkeypatch.setenv("TEST_TMPDIR", str(tmp_path))
    monkeypatch.chdir(tmp_path)
    member(tmp_path)
    return calls


def test_install_members(uv_runs: list[tuple[list[str], dict[str, str]]]) -> None:
    site, scripts = launch.install_members(["m"])
    [(command, env)] = uv_runs
    prefix = Path(command[command.index("--prefix") + 1])
    assert prefix.parent == Path(os.environ["TEST_TMPDIR"])
    assert prefix.name.startswith("members-")
    assert command == [
        "/env/uv",
        "pip",
        "install",
        "--quiet",
        "--offline",
        "--no-deps",
        "--python",
        sys.executable,
        "--prefix",
        str(prefix),
        str(prefix / "demo_pkg_x-1.2.3-py3-none-any.whl"),
    ]
    assert env["UV_CACHE_DIR"] == str(prefix / "cache")
    assert env["UV_NO_CONFIG"] == "1"
    assert env["TBHB_PYTHON_UV"] == "/env/uv"
    paths = {"base": str(prefix)}
    assert site == sysconfig.get_path("purelib", vars=paths)
    assert scripts == sysconfig.get_path("scripts", vars=paths)


def test_install_members_reports_a_failed_install(
    uv_runs: list[tuple[list[str], dict[str, str]]],
) -> None:
    codes = getattr(launch, "uv_codes")  # noqa: B009
    codes[0] = 3
    with pytest.raises(
        launch.UsageError,
        match=r"^installing the workspace members failed \(3\)$",
    ):
        launch.install_members(["m"])
    assert len(uv_runs) == 1


@pytest.mark.parametrize(
    ("pythonpath", "path"),
    [(None, None), ("/a", "/b")],
)
def test_use_members(
    monkeypatch: pytest.MonkeyPatch,
    pythonpath: str | None,
    path: str | None,
) -> None:
    for name, value in (("PYTHONPATH", pythonpath), ("PATH", path)):
        if value is None:
            monkeypatch.delenv(name, raising=False)
        else:
            monkeypatch.setenv(name, value)
    asked: list[list[str]] = []

    def fake_install(members: list[str]) -> tuple[str, str]:
        asked.append(members)
        return "/site", "/scripts"

    monkeypatch.setattr(launch, "install_members", fake_install)
    monkeypatch.setattr(sys, "path", [*sys.path])
    launch.use_members(["m"])
    assert asked == [["m"]]
    assert sys.path[-1] == "/site"
    sep = os.pathsep
    assert os.environ["PYTHONPATH"] == (f"/a{sep}/site" if pythonpath else "/site")
    assert os.environ["PATH"] == (f"/scripts{sep}/b" if path else "/scripts")


def test_main_installs_members_before_changing_directory(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "cli").mkdir()
    monkeypatch.chdir(tmp_path)
    seen: list[tuple[list[str], str]] = []

    def fake_use(members: list[str]) -> None:
        seen.append((members, Path.cwd().name))

    def fake_run(tool: str, args: list[str]) -> int:
        assert tool == "pytest"
        return len(args)

    monkeypatch.setattr(launch, "use_members", fake_use)
    monkeypatch.setattr(launch, "run", fake_run)
    argv = ["--member", "cli", "--member", ".", "--chdir", "cli", "--", "pytest", "x"]
    assert launch.main(argv) == 1
    assert seen == [(["cli", "."], tmp_path.name)]


def test_main_reports_a_failed_member_install(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def refuse(_: list[str]) -> None:
        message = "installing the workspace members failed (3)"
        raise launch.UsageError(message)

    monkeypatch.setattr(launch, "use_members", refuse)
    assert launch.main(["--member", "m", "--", "pytest"]) == 2
    assert capsys.readouterr().err == (
        "launch.py: installing the workspace members failed (3)\n"
    )


def test_main_without_members_installs_nothing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run(tool: str, args: list[str]) -> int:
        return 5 if (tool, args) == ("pytest", []) else 1

    monkeypatch.setattr(launch, "use_members", None)
    monkeypatch.setattr(launch, "run", fake_run)
    assert launch.main(["--", "pytest"]) == 5
