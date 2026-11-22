# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import os
import subprocess
import sys

import pytest

from lint.private.review_policy import check_review_policy as checker

FINDINGS = {
    "ok": False,
    "findings": [
        {"path": ".github/a.toml", "id": "config-schema", "message": "bad"},
        {"path": ".github/b.md", "id": "template-guidance", "message": "worse"},
    ],
}


@pytest.mark.parametrize(
    "case",
    [
        (0, '{"ok": true, "findings": []}', "", 0, "review_policy: no findings\n"),
        (
            1,
            json.dumps(FINDINGS),
            "",
            1,
            (
                ".github/a.toml: config-schema: bad\n"
                ".github/b.md: template-guidance: worse\n"
            ),
        ),
        (
            2,
            json.dumps({"ok": False, "error": "floor-load", "message": "no floor"}),
            "tbhbdev: no floor",
            1,
            "no floor\n",
        ),
        (
            1,
            '{"ok": false, "findings": []}',
            "",
            1,
            'exit status 1\n{"ok": false, "findings": []}\n',
        ),
        (1, '{"findings": 3}', "", 1, 'exit status 1\n{"findings": 3}\n'),
        (1, '{"findings": [3]}', "", 1, 'exit status 1\n{"findings": [3]}\n'),
        (2, "not json", "boom", 1, "exit status 2\nnot json\nboom\n"),
        (2, "[1]", "", 1, "exit status 2\n[1]\n"),
        (2, '{"message": 5}', "", 1, 'exit status 2\n{"message": 5}\n'),
        (3, "", "crash", 1, "exit status 3\ncrash\n"),
    ],
)
def test_verdict(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    case: tuple[int, str, str, int, str],
) -> None:
    code, stdout, stderr, status, output = case
    calls: list[tuple[list[str], dict[str, str]]] = []

    def run(
        command: list[str], *, env: dict[str, str], **_: object
    ) -> subprocess.CompletedProcess[str]:
        calls.append((command, env))
        return subprocess.CompletedProcess(command, code, stdout, stderr)

    monkeypatch.setenv("PYTHONPATH", "boot")
    monkeypatch.setattr(subprocess, "run", run)

    assert checker.main(["src", "tree"]) == status
    assert capsys.readouterr().out == output
    assert calls[0][0] == [
        sys.executable,
        "-m",
        "tbhbdev",
        "alpha",
        "review",
        "policy",
        "check",
        "tree",
        "--json",
    ]
    assert calls[0][1]["PYTHONPATH"].split(os.pathsep) == ["src", "boot"]


def test_python_path_without_inherited_one(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    def run(
        command: list[str], *, env: dict[str, str], **_: object
    ) -> subprocess.CompletedProcess[str]:
        seen.append(env["PYTHONPATH"])
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.delenv("PYTHONPATH", raising=False)
    monkeypatch.setattr(subprocess, "run", run)

    assert checker.main(["src", "tree"]) == 0
    assert seen == ["src"]
