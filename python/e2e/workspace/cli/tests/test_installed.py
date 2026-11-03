# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import io
import subprocess
from importlib import metadata

import pytest
from tbhbops import layout


def test_the_member_is_installed() -> None:
    assert metadata.version("tbhbops") == "0.1.0"


def test_its_console_script_runs() -> None:
    done = subprocess.run(
        ["tbhbops-layout"], input="b\n\na\n", capture_output=True, text=True, check=True
    )
    assert done.stdout == "2\n"


def test_main(
    capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO("x\n\ny\nz\n"))
    layout.main()
    assert capsys.readouterr().out == "3\n"
