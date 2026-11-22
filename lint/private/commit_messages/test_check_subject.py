# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import io
from typing import TYPE_CHECKING

import pytest

from lint.private.commit_messages import check_subject as cs

if TYPE_CHECKING:
    from pathlib import Path


@pytest.mark.parametrize(
    "subject",
    [
        "feat(lint): check each commit message",
        "fix: handle an empty range",
        "chore(deps): update uv to v0.13.9",
        "refactor(api)!: drop the old route",
        "docs: " + "y" * 66,
        'Revert "feat(x): y"',
        'Reapply "feat(x): y"',
        "chore(deps): update dependency @opentelemetry/instrumentation-http to v0.57.0",
        "chore(deps): pin dependency @opentelemetry/instrumentation-http to v0.57.0",
        "chore(deps): pin ghcr.io/home-assistant/home-assistant docker tag to 1234567",
        "chore(deps): pin docker.io/library/node docker tag to sha256:" + "a" * 64,
        "feat: wipe the cache",
    ],
)
def test_accepts(subject: str) -> None:
    assert cs.problems(subject) == []


@pytest.mark.parametrize(
    ("subject", "problem"),
    [
        ("fixup! feat: x", "fixup!, squash! and amend! subjects must be reworded"),
        ("squash! feat: x", "fixup!, squash! and amend! subjects must be reworded"),
        ("amend! feat: x", "fixup!, squash! and amend! subjects must be reworded"),
        ("WIP: feat: x", "WIP subjects are not allowed"),
        ("feat: [wip] parser", "WIP subjects are not allowed"),
        ("feat: WIP, add x", "WIP subjects are not allowed"),
        ("feat: x " + "y" * 70, "subject is 78 characters; the limit is 72"),
        ("feat: " + "y" * 67, "subject is 73 characters; the limit is 72"),
        ("update the thing", "subject must have the form type(scope): summary"),
        ("feat(): x", "subject must have the form type(scope): summary"),
        ("fix", "subject is too generic; say what changed"),
        ("address review", "subject is too generic; say what changed"),
        ("fix: update", "subject is too generic; say what changed"),
        ("chore: Changes.", "subject is too generic; say what changed"),
    ],
)
def test_rejects(subject: str, problem: str) -> None:
    assert problem in cs.problems(subject)


def test_main_reads_first_line_of_stdin(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO("fix\r\n\nbody mentions wip"))
    assert cs.main(["check_subject"]) == 1
    out = capsys.readouterr().out
    assert "too generic" in out
    assert "WIP" not in out


def test_main_reads_file_and_passes(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    f = tmp_path / "msg"
    f.write_text("feat(lint): add a check\n\nbody")
    assert cs.main(["check_subject", str(f)]) == 0
    assert capsys.readouterr().out == ""
