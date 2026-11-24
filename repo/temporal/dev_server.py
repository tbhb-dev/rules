# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001

"""Run a command against an isolated, in-memory Temporal development server."""

import os
import signal
import socket
import subprocess  # nosec B404
import sys
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Sequence
    from types import FrameType
    from typing import BinaryIO, Never

HOST = "127.0.0.1"
PORT_FLAGS = ("--port", "--ui-port", "--http-port", "--metrics-port")
STARTUP_TIMEOUT = 30
STOP_TIMEOUT = 2


def _free_ports() -> list[int]:
    # Hold all reservations until every port has been assigned.
    with ExitStack() as reservations:
        ports = []
        for _ in PORT_FLAGS:
            listener = reservations.enter_context(socket.socket())
            listener.bind((HOST, 0))
            ports.append(listener.getsockname()[1])
        return ports


def _wait_ready(
    server: subprocess.Popen[bytes],
    port: int,
    log: BinaryIO,
    deadline: float,
) -> bool:
    announced = False
    while time.monotonic() < deadline:
        if server.poll() is not None:
            return False
        # The CLI prints this after startup. A TCP probe alone could connect
        # to another process that claimed the port between reservation and bind.
        if not announced:
            announced = any(line.startswith(b"Temporal Server:") for line in log)
        if announced:
            try:
                with socket.create_connection((HOST, port), timeout=0.1):
                    return True
            except OSError:
                pass
        time.sleep(0.05)
    log.seek(0)
    output = log.read().decode(errors="replace")
    msg = f"Temporal frontend did not become ready at {HOST}:{port}\n{output}"
    raise TimeoutError(msg)


def _stop(server: subprocess.Popen[bytes]) -> None:
    if server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=STOP_TIMEOUT)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


def _start(
    cli: Sequence[str],
    directory: str,
    deadline: float,
    running: ExitStack,
) -> tuple[subprocess.Popen[bytes], str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("TEMPORAL_")
    }
    env.update(
        dict.fromkeys(("HOME", "XDG_CONFIG_HOME", "APPDATA", "USERPROFILE"), directory)
    )
    env["NO_COLOR"] = "1"
    log_path = Path(directory) / "server.log"

    # Temporal needs explicit ports and cannot inherit bound sockets. Try
    # fresh ports if another process wins a port before Temporal binds it.
    for _ in range(3):
        ports = _free_ports()
        args = [*cli, "server", "start-dev", "--ip", HOST, "--headless"]
        for flag, port in zip(PORT_FLAGS, ports, strict=True):
            args.extend((flag, str(port)))
        with log_path.open("wb") as output:
            # Bazel supplies the CLI.
            server = subprocess.Popen(  # nosec B603  # noqa: S603
                args,
                cwd=directory,
                env=env,
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            running.callback(_stop, server)
        with log_path.open("rb") as log:
            if _wait_ready(server, ports[0], log, deadline):
                return server, f"{HOST}:{ports[0]}"
    output = log_path.read_text(encoding="utf-8", errors="replace")
    msg = f"Temporal exited during startup:\n{output}"
    raise RuntimeError(msg)


def run(cli: Sequence[str], command: Sequence[str], timeout: float | None) -> int:
    deadline = time.monotonic() + timeout if timeout is not None else float("inf")
    with (
        tempfile.TemporaryDirectory(prefix="temporal-dev-") as directory,
        ExitStack() as running,
    ):
        server, address = _start(
            cli, directory, min(time.monotonic() + STARTUP_TIMEOUT, deadline), running
        )
        sys.stdout.write(f"TEMPORAL_ADDRESS={address}\n")
        sys.stdout.flush()
        if not command:
            return server.wait()
        remaining = None if timeout is None else max(0, deadline - time.monotonic())
        # The caller selects the command.
        return subprocess.run(  # nosec B603  # noqa: S603
            command,
            check=False,
            env={**os.environ, "TEMPORAL_ADDRESS": address},
            timeout=remaining,
        ).returncode


def _interrupt(signal_number: int, _frame: FrameType | None) -> Never:
    raise SystemExit(128 + signal_number)


def main() -> int:
    signal.signal(signal.SIGINT, _interrupt)
    signal.signal(signal.SIGTERM, _interrupt)
    cli, *command = sys.argv[1:]
    bazel_timeout = os.environ.get("TEST_TIMEOUT")
    # Leave time to stop and reap the server before Bazel's deadline.
    timeout = max(1, int(bazel_timeout) - 5) if bazel_timeout else None
    try:
        return run([cli], command, timeout)
    except (subprocess.TimeoutExpired, OSError, RuntimeError) as error:
        sys.stderr.write(f"Temporal dev server: {error}\n")
        return 124 if isinstance(error, subprocess.TimeoutExpired) else 1


if __name__ == "__main__":
    sys.exit(main())
