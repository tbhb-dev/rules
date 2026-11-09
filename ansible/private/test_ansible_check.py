# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import re
import signal
import sys
import time
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from private import ansible_check

if TYPE_CHECKING:
    from collections.abc import Mapping, Sequence

type Call = tuple[list[str], dict[str, str], Path | None]


@pytest.fixture
def calls(monkeypatch: pytest.MonkeyPatch) -> list[Call]:
    """Record each tool command instead of running it.

    A command fails when its last argument names `bad`.
    """
    recorded: list[Call] = []

    class Done:
        def __init__(self, returncode: int) -> None:
            self.returncode = returncode

    def fake_run(
        command: Sequence[str], *, env: Mapping[str, str], cwd: Path | None, check: bool
    ) -> Done:
        assert not check
        recorded.append((list(command), dict(env), cwd))
        return Done(1 if "bad" in command[-1] else 0)

    monkeypatch.setattr(ansible_check.subprocess, "run", fake_run)
    return recorded


def test_environment_uses_the_tree_config_and_pinned_collections(
    tmp_path: Path,
) -> None:
    root, tmp = tmp_path / "tree", tmp_path / "tmp"
    root.mkdir()
    tmp.mkdir()
    (root / "ansible.cfg").write_text("[defaults]\n")
    env = ansible_check.environment(
        root, tmp, {"TBHB_ANSIBLE_COLLECTIONS": "/a::/b", "KEEP": "1"}
    )
    assert env["KEEP"] == "1"
    assert env["ANSIBLE_CONFIG"] == str(root / "ansible.cfg")
    assert env["ANSIBLE_COLLECTIONS_PATH"] == "/a:/b"
    assert env["ANSIBLE_COLLECTIONS_SCAN_SYS_PATH"] == "false"
    for key in ("ANSIBLE_HOME", "ANSIBLE_LOCAL_TEMP", "ANSIBLE_REMOTE_TEMP"):
        assert Path(env[key]).parent == tmp
    assert env["ANSIBLE_INVENTORY_UNPARSED_FAILED"] == "true"
    assert env["ANSIBLE_INVENTORY_ANY_UNPARSED_IS_FAILED"] == "true"


def test_environment_without_config_or_collections_stays_inside_tmp(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    env = ansible_check.environment(tmp_path / "tree", tmp_path, {})
    assert env["ANSIBLE_CONFIG"] == str(tmp_path / "ansible.cfg")
    assert (tmp_path / "ansible.cfg").read_text() == ""
    assert env["ANSIBLE_COLLECTIONS_PATH"] == str(tmp_path / "collections")
    assert (tmp_path / "collections").is_dir()
    assert "using an empty one" in capsys.readouterr().out


def test_syntax_lists_the_inventory_then_checks_each_playbook(
    calls: list[Call], capsys: pytest.CaptureFixture[str]
) -> None:
    assert ansible_check.syntax("hosts.yml", ["a.yml", "b.yml"], {}) == 0
    assert [c[0] for c in calls] == [
        ["ansible-inventory", "--list", "-i", "hosts.yml"],
        ["ansible-playbook", "--syntax-check", "-i", "hosts.yml", "a.yml"],
        ["ansible-playbook", "--syntax-check", "-i", "hosts.yml", "b.yml"],
    ]
    assert "inventory and 2 playbook(s) passed" in capsys.readouterr().out


def test_syntax_reports_every_failure(
    calls: list[Call], capsys: pytest.CaptureFixture[str]
) -> None:
    assert ansible_check.syntax("bad.ini", ["ok.yml", "bad.yml"], {}) == 1
    assert len(calls) == 3
    assert "FAIL: inventory bad.ini, playbook bad.yml" in capsys.readouterr().err


def test_lint_config_prefers_the_checks_config(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / ".ansible-lint").write_text("")
    assert (
        ansible_check.lint_config(tmp_path, "cfg/lint.yml", {})
        == tmp_path / "cfg/lint.yml"
    )
    assert "cfg/lint.yml (the check's `config`)" in capsys.readouterr().out


def test_lint_config_finds_the_trees_own(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / ".config").mkdir()
    (tmp_path / ".config/ansible-lint.yml").write_text("")
    assert (
        ansible_check.lint_config(tmp_path, "", {})
        == tmp_path / ".config/ansible-lint.yml"
    )
    assert ".config/ansible-lint.yml (the tree's own)" in capsys.readouterr().out


def test_lint_config_falls_back_to_the_default(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    default = tmp_path / "default.yml"
    default.write_text("profile: production\n")
    root = tmp_path / "tree"
    root.mkdir()
    config = ansible_check.lint_config(
        root, "", {"TBHB_ANSIBLE_LINT_DEFAULT_CONFIG": str(default)}
    )
    assert config == root / ".ansible-lint"
    assert config.read_text() == "profile: production\n"
    assert "tbhb_rules_ansible's default" in capsys.readouterr().out


@pytest.fixture
def tree(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "tree"
    root.mkdir()
    (root / ".ansible-lint").write_text("")
    tmp = tmp_path / "tmp"
    tmp.mkdir()
    monkeypatch.chdir(root)
    monkeypatch.setenv("TEST_TMPDIR", str(tmp))
    monkeypatch.delenv("TBHB_ANSIBLE_COLLECTIONS", raising=False)
    return root


@pytest.mark.usefixtures("tree")
def test_main_syntax(calls: list[Call]) -> None:
    assert (
        ansible_check.main(
            ["syntax", "--inventory", "hosts.yml", "site.yml", "extra.yml"]
        )
        == 0
    )
    assert calls[-1][0][-1] == "extra.yml"


def test_main_lint_runs_offline_with_the_chosen_config(
    tree: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    watched: list[tuple[list[str], dict[str, str], float]] = []

    def fake_run_watched(
        command: Sequence[str], env: Mapping[str, str], timeout: float
    ) -> int:
        watched.append((list(command), dict(env), timeout))
        return 0

    monkeypatch.setattr(ansible_check, "run_watched", fake_run_watched)
    monkeypatch.delenv("TBHB_ANSIBLE_CHECK_TIMEOUT", raising=False)
    monkeypatch.setenv("TEST_TIMEOUT", "100")
    assert ansible_check.main(["lint", "roles/"]) == 0
    assert watched == [
        (
            [
                "ansible-lint",
                "--offline",
                "--project-dir",
                ".",
                "-c",
                str(tree / ".ansible-lint"),
                "roles/",
            ],
            watched[0][1],
            80.0,
        )
    ]
    assert watched[0][1]["ANSIBLE_CONFIG"].endswith("ansible.cfg")
    assert watched[0][1]["PYTHONUNBUFFERED"] == "1"


def test_main_molecule_runs_from_the_role(tree: Path, calls: list[Call]) -> None:
    assert (
        ansible_check.main(["molecule", "--role", "roles/web", "--scenario", "bad"])
        == 1
    )
    command, env, cwd = calls[0]
    assert command == ["molecule", "test", "-s", "bad"]
    assert cwd == tree / "roles/web"
    assert env["MOLECULE_EPHEMERAL_DIRECTORY"] == str(
        Path(env["TEST_TMPDIR"]) / "molecule"
    )


MARKER = "argv-marker-31415"
# Prints its process id and a progress line, then waits to be killed.
HANG = "import os,time;print('pid',os.getpid(),flush=True);print('last: roles/web',flush=True);time.sleep(30)"  # noqa: E501


# The driver runs on Linux and macOS only, but this suite also runs on
# Windows, which has no process groups. The tests of real groups skip there;
# pyproject.toml excludes the functions behind this decorator from coverage.
posix_only = pytest.mark.skipif(
    sys.platform == "win32", reason="needs POSIX process groups"
)


def test_watchdog_ends_the_group_with_sigterm_then_sigkill(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Runs on every platform, with the group calls faked (no groups on Windows)."""
    sent: list[int] = []

    def fake_killpg(pid: int, sig: int) -> None:
        sent.append(sig)
        if len(sent) > 1:
            raise ProcessLookupError  # the child is gone already
        os.kill(pid, signal.SIGTERM)

    monkeypatch.setattr(os, "killpg", fake_killpg, raising=False)
    monkeypatch.setattr(signal, "SIGKILL", 9, raising=False)
    code = ansible_check.run_watched([sys.executable, "-c", HANG], dict(os.environ), 1)
    assert code == 124
    assert sent == [signal.SIGTERM, 9]
    assert "watchdog fired after 1s" in capsys.readouterr().out


@posix_only
def test_watchdog_reports_before_killing_and_clears_the_group(
    capsys: pytest.CaptureFixture[str],
) -> None:
    started = time.monotonic()
    code = ansible_check.run_watched(
        [sys.executable, "-c", HANG, MARKER], dict(os.environ), timeout=1
    )
    out = capsys.readouterr().out
    assert code == ansible_check.TIMED_OUT == 124
    assert time.monotonic() - started < 20
    assert "ansible_check: watchdog fired after 1s, ansible-lint did not finish" in out
    assert "PID" in out
    assert "load average" in out
    # nproc is missing from a stock macOS.
    assert re.search(r"^(\d+|nproc unavailable)$", out, re.MULTILINE)
    assert "last: roles/web" in out.split("last output lines:")[1]
    match = re.search(r"^pid (\d+)$", out, re.MULTILINE)
    assert match
    with pytest.raises(ProcessLookupError):
        os.killpg(int(match[1]), 0)


@posix_only
def test_watchdog_never_prints_the_command_line_after_the_header(
    capsys: pytest.CaptureFixture[str],
) -> None:
    ansible_check.run_watched(
        [sys.executable, "-c", HANG, MARKER], dict(os.environ), timeout=1
    )
    report = capsys.readouterr().out.split("watchdog fired", 1)[1]
    assert MARKER not in report


@posix_only
def test_watchdog_kills_a_child_that_ignores_sigterm(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(ansible_check, "GRACE", 0.5)
    stubborn = "import signal;signal.signal(signal.SIGTERM,signal.SIG_IGN);" + HANG
    assert (
        ansible_check.run_watched([sys.executable, "-c", stubborn], dict(os.environ), 1)
        == 124
    )
    match = re.search(r"^pid (\d+)$", capsys.readouterr().out, re.MULTILINE)
    assert match
    with pytest.raises(ProcessLookupError):
        os.killpg(int(match[1]), 0)


def test_watchdog_passes_the_exit_code_through(
    capsys: pytest.CaptureFixture[str],
) -> None:
    code = ansible_check.run_watched(
        [sys.executable, "-c", "import sys;print('hi');sys.exit(3)"],
        dict(os.environ),
        timeout=30,
    )
    out = capsys.readouterr().out
    assert code == 3
    assert "hi" in out
    assert "watchdog fired" not in out


@posix_only
def test_watchdog_keeps_only_the_last_twenty_lines(
    capsys: pytest.CaptureFixture[str],
) -> None:
    script = "print(*range(30),sep='\\n',flush=True);import time;time.sleep(30)"
    ansible_check.run_watched([sys.executable, "-c", script], dict(os.environ), 2)
    report = capsys.readouterr().out.split("last output lines:")[1]
    assert "  29" in report
    assert "  10" in report
    assert "  9\n" not in report


@pytest.mark.parametrize(
    ("environ", "expected"),
    [
        ({"TEST_TIMEOUT": "300"}, 240.0),
        ({"TEST_TIMEOUT": "100"}, 80.0),
        ({}, 240.0),
        ({"TEST_TIMEOUT": "soon"}, 240.0),
        ({"TEST_TIMEOUT": "0"}, 240.0),
        ({"TEST_TIMEOUT": "100", "TBHB_ANSIBLE_CHECK_TIMEOUT": "1.5"}, 1.5),
        ({"TEST_TIMEOUT": "100", "TBHB_ANSIBLE_CHECK_TIMEOUT": "x"}, 80.0),
    ],
)
def test_watchdog_timeout(environ: dict[str, str], expected: float) -> None:
    assert ansible_check.watchdog_timeout(environ) == expected


def test_process_table_falls_back_without_forest(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen: list[list[str]] = []

    class Done:
        def __init__(self, returncode: int) -> None:
            self.returncode = returncode
            self.stdout = "PID table"

    def fake_run(command: list[str], **_: object) -> Done:
        seen.append(command)
        return Done(1 if "--forest" in command else 0)

    monkeypatch.setattr(ansible_check.subprocess, "run", fake_run)
    assert ansible_check.process_table() == "PID table"
    assert "--forest" in seen[0]
    assert "--forest" not in seen[1]
    assert all("args" not in c and "command" not in c for c in seen)


def test_process_table_reports_a_failing_or_missing_ps(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Failed:
        returncode = 1
        stdout = ""

    def failed(*_: object, **__: object) -> Failed:
        return Failed()

    monkeypatch.setattr(ansible_check.subprocess, "run", failed)
    assert ansible_check.process_table() == "ps failed"

    def missing(*_: object, **__: object) -> None:
        msg = "ps"
        raise FileNotFoundError(msg)

    monkeypatch.setattr(ansible_check.subprocess, "run", missing)
    assert "ps is unavailable" in ansible_check.process_table()


def test_host_load_says_when_a_binary_is_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Done:
        stdout = "up 1 day\n"

    def fake_run(command: list[str], **_: object) -> Done:
        if command == ["nproc"]:
            msg = "nproc"
            raise FileNotFoundError(msg)
        return Done()

    monkeypatch.setattr(ansible_check.subprocess, "run", fake_run)
    assert ansible_check.host_load() == "up 1 day\nnproc unavailable"
