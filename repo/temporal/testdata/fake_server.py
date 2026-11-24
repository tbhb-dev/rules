# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A loopback-only stand-in for `temporal server start-dev`."""

import argparse
import os
import signal
import socket
import sys
import time
from contextlib import ExitStack
from pathlib import Path


def main() -> int:
    assert sys.argv[1:3] == ["server", "start-dev"]
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", required=True)
    parser.add_argument("--headless", action="store_true", required=True)
    for flag in ("--port", "--ui-port", "--http-port", "--metrics-port"):
        parser.add_argument(flag, type=int, required=True)
    args = parser.parse_args(sys.argv[3:])
    assert args.ip == "127.0.0.1"
    ports = (args.port, args.ui_port, args.http_port, args.metrics_port)
    assert len(set(ports)) == 4 and min(ports) > 0
    assert not any(key.startswith("TEMPORAL_") for key in os.environ)
    home = Path(os.environ["HOME"])
    assert home == Path.cwd()
    assert os.environ["XDG_CONFIG_HOME"] == str(home)
    state = Path(os.environ["FAKE_STATE"])
    mode = os.environ.get("FAKE_MODE", "ready")
    (state / f"server-{os.getpid()}").write_text(
        f"{args.port}\n{home}", encoding="utf-8"
    )
    retry_marker = home / "retry"
    if mode == "exit" or (mode == "retry" and not retry_marker.exists()):
        retry_marker.touch()
        print("fake bind failure", flush=True)
        return 1
    if mode == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if mode == "probe":
        print(f"Temporal Server: localhost:{args.port}", flush=True)
        time.sleep(0.2)
    with ExitStack() as sockets:
        listeners = []
        for port in ports:
            listener = sockets.enter_context(socket.socket())
            listener.bind((args.ip, port))
            listener.listen()
            listeners.append(listener)
        if mode not in {"stall", "probe"}:
            print(f"Temporal Server: localhost:{args.port}", flush=True)
        if mode == "standalone":
            connection, _ = listeners[0].accept()
            with connection:
                return 9
        signal.pause()
    return 0


if __name__ == "__main__":
    sys.exit(main())
