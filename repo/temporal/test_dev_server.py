# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import os
import signal
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import Mock

import pytest

from repo.temporal import dev_server

CLI = [sys.executable, str(Path(__file__).parent / "testdata" / "fake_server.py")]
CONNECT = """
import os, socket
host, port = os.environ['TEMPORAL_ADDRESS'].split(':')
with socket.create_connection((host, int(port)), timeout=1):
    pass
"""


@pytest.fixture
def state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("FAKE_STATE", str(tmp_path))
    monkeypatch.setenv("TEMPORAL_ADDRESS", "ignore-this:1234")
    return tmp_path


def _stopped(state: Path, count: int) -> set[tuple[str, str]]:
    servers = sorted(state.glob("server-*"))
    assert len(servers) == count
    instances = set()
    for server in servers:
        port, directory = server.read_text(encoding="utf-8").splitlines()
        with pytest.raises(ProcessLookupError):
            os.kill(int(server.name.removeprefix("server-")), 0)
        assert not Path(directory).exists()
        instances.add((port, directory))
    return instances


@pytest.mark.parametrize(("mode", "status"), [("probe", 0), ("retry", 7)])
def test_runs_command_and_cleans_up(
    state: Path,
    monkeypatch: pytest.MonkeyPatch,
    mode: str,
    status: int,
) -> None:
    monkeypatch.setenv("FAKE_MODE", mode)
    command = [sys.executable, "-c", CONNECT + f"raise SystemExit({status})"]
    assert dev_server.run(CLI, command, None) == status
    _stopped(state, 2 if mode == "retry" else 1)


def test_concurrent_servers(state: Path) -> None:
    code = (
        CONNECT
        + """
from pathlib import Path
from time import monotonic, sleep
state = Path(os.environ['FAKE_STATE'])
(state / ('command-' + port)).touch()
deadline = monotonic() + 5
while len(list(state.glob('command-*'))) < 2:
    assert monotonic() < deadline
    sleep(0.02)
"""
    )
    command = [sys.executable, "-c", code]
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(dev_server.run, CLI, command, 10) for _ in range(2)]
        assert [future.result() for future in futures] == [0, 0]
    ports, directories = map(set, zip(*_stopped(state, 2), strict=True))
    assert len(ports) == len(directories) == 2


def test_startup_deadline(state: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FAKE_MODE", "stall")
    monkeypatch.setattr(dev_server, "STARTUP_TIMEOUT", 2)
    with pytest.raises(TimeoutError, match="did not become ready"):
        dev_server.run(CLI, ["must-not-run"], None)
    _stopped(state, 1)


def test_early_exit_reports_log(state: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FAKE_MODE", "exit")
    with pytest.raises(RuntimeError, match="fake bind failure"):
        dev_server.run(CLI, ["must-not-run"], None)
    _stopped(state, 3)


def test_command_timeout_kills_unresponsive_server(
    state: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FAKE_MODE", "ignore-term")
    monkeypatch.setattr(dev_server, "STOP_TIMEOUT", 0.1)
    command = [sys.executable, "-c", CONNECT + "from time import sleep; sleep(60)"]
    with pytest.raises(subprocess.TimeoutExpired):
        dev_server.run(CLI, command, 3)
    _stopped(state, 1)


def test_foreground_server_status(state: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FAKE_MODE", "standalone")
    assert dev_server.run(CLI, [], None) == 9
    _stopped(state, 1)


@pytest.mark.parametrize("signal_number", [signal.SIGINT, signal.SIGTERM])
def test_interrupt_cleans_up(state: Path, signal_number: signal.Signals) -> None:
    code = """
import signal, sys
from repo.temporal import dev_server
signal.signal(int(sys.argv[1]), dev_server._interrupt)
sys.exit(dev_server.run(sys.argv[2:], [], None))
"""
    with subprocess.Popen(
        [sys.executable, "-c", code, str(signal_number), *CLI],
        stdout=subprocess.PIPE,
        text=True,
    ) as child:
        try:
            assert child.stdout is not None
            assert child.stdout.readline().startswith("TEMPORAL_ADDRESS=127.0.0.1:")
            child.send_signal(signal_number)
            assert child.wait(timeout=5) == 128 + signal_number
        finally:
            child.kill()
    _stopped(state, 1)
    with pytest.raises(SystemExit) as exit_info:
        dev_server._interrupt(signal_number, None)  # noqa: SLF001
    assert exit_info.value.code == 128 + signal_number


@pytest.mark.parametrize(
    ("budget", "result", "expected_timeout", "status"),
    [
        ("", 7, None, 7),
        ("60", subprocess.TimeoutExpired("test", 55), 55, 124),
        ("3", OSError("failure"), 1, 1),
    ],
)
def test_main(
    monkeypatch: pytest.MonkeyPatch,
    budget: str,
    result: int | Exception,
    expected_timeout: float | None,
    status: int,
) -> None:
    run = Mock(side_effect=[result])
    monkeypatch.setattr(signal, "signal", Mock())
    monkeypatch.setattr(sys, "argv", ["dev_server.py", "cli", "test"])
    monkeypatch.setenv("TEST_TIMEOUT", budget)
    monkeypatch.setattr(dev_server, "run", run)
    assert dev_server.main() == status
    run.assert_called_once_with(["cli"], ["test"], expected_timeout)
