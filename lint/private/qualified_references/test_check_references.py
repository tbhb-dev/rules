# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import io
import os
import subprocess
import sys
from typing import TYPE_CHECKING

import pytest

from lint.private.qualified_references.check_references import bare_references, main

if TYPE_CHECKING:
    from pathlib import Path


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("See #12, #34, and #56.", [(1, "#12"), (1, "#34"), (1, "#56")]),
        ("See **#123** and Fixes #456.", [(1, "#123"), (1, "#456")]),
        ("#1\n\nSee #42.", [(1, "#1"), (3, "#42")]),
        ("See\n#42 and  \n#43.", [(1, "#42"), (1, "#43")]),
        ("See acme/repo#12 or tbhb-dev/rules.foo_bar-2#123.", []),
        ("See [issue #42](https://example.com/#44).", [(1, "#42")]),
        ("Follow [#42](42).", [(1, "#42")]),
        ("[#42](#42) and [section][target].\n\n[target]: guide.md#33", []),
        ("Use anchor #12 or [#42](docs/guide.md#42).", []),
        (
            (
                "https://example.com/#12 <https://example.com/#22> "
                "example.com/guide#32 and ./guide.md#42"
            ),
            [],
        ),
        ("Use docs/setup/guide.md#32 or mailto:docs@example.com#42.", []),
        ("Use <code title='a>b'>#12</code> and see #22.", [(1, "#22")]),
        ("Use <a id='#12'></a> and <code class='literal'>#22</code>.", []),
        ("Use #fff, #00ff88, #123, #1234, #123456, and #12345678.", []),
        ("Use #42-setup, ##43, and ![image #44](image.png).", []),
        ("Use `#12` and ``x ` #22`` here.\n\n```sh\n#33\n```", []),
        ("> ~~~\n> #42\n> ~~~\n\n    #44", []),
        ("# Heading #12\n\nTitle #22\n=========\n\n> ## Heading #33", []),
    ],
)
def test_bare_references(source: str, expected: list[tuple[int, str]]) -> None:
    assert list(bare_references(source)) == expected


@pytest.mark.parametrize(
    ("kind", "source", "locations"),
    [
        ("pr-text", "Update (#12)\n\nSee #34", ["title", "body:1"]),
        ("pr-text", "Merge pull request #12 from owner/branch", ["title"]),
        ("commit", "Merge pull request #12 from owner/branch", []),
        ("commit", "Merge pull request #12\n\nSee #42", ["body:1"]),
        ("commit", "Fix #12 (#34)\n\nDetails", ["title"]),
        ("commit", "Fix owner/repo#12 (#34)\n\nSee owner/repo#56", []),
        ("pr-text", "Update owner/repo#12\n\nSee other/repo#42", []),
        ("pr-text", "Update\n\n```\n#12\n```\n\nSee #34", ["body:5"]),
    ],
)
def test_text(
    kind: str,
    source: str,
    locations: list[str],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(sys, "stdin", io.StringIO(source))
    assert main([kind]) == bool(locations)
    assert [
        line.removeprefix("fail: ").partition(": qualify")[0]
        for line in capsys.readouterr().out.splitlines()
    ] == locations


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True)


def test_docs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_TEMPLATE_DIR", "")
    git(tmp_path, "init", "-q")
    git(tmp_path, "config", "user.name", "Test")
    git(tmp_path, "config", "user.email", "test@example.invalid")
    (tmp_path / "old.md").write_text("See #12.", encoding="utf-8")
    (tmp_path / "removed.md").write_text("See #56.", encoding="utf-8")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-qm", "Base")

    assert main(["docs", "--base", "HEAD", "--head", "HEAD"]) == 0
    assert capsys.readouterr().out == ""

    (tmp_path / "removed.md").unlink()
    (tmp_path / "new name.MD").write_text("Fix #34.", encoding="utf-8")
    (tmp_path / "text.txt").write_text("See #78.", encoding="utf-8")
    (tmp_path / "testdata").mkdir()
    (tmp_path / "testdata/fixture.md").write_text("See #90.", encoding="utf-8")
    (tmp_path / "symlink.md").symlink_to("old.md")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-qm", "Add documents")
    (tmp_path / "new name.MD").write_text("Fix owner/repo#34.", encoding="utf-8")

    assert main(["docs", "--base", "HEAD^"]) == 1
    assert capsys.readouterr().out == (
        "fail: new name.MD:1: qualify #34 as owner/repo#34\n"
    )
    assert main(["docs"]) == 0
    assert capsys.readouterr().out.splitlines() == [
        "warn: new name.MD:1: qualify #34 as owner/repo#34",
        "warn: old.md:1: qualify #12 as owner/repo#12",
    ]
    assert main(["docs", "--mode", "fail", "--head", "HEAD^"]) == 1
    assert capsys.readouterr().out.splitlines() == [
        "fail: old.md:1: qualify #12 as owner/repo#12",
        "fail: removed.md:1: qualify #56 as owner/repo#56",
    ]
    assert main(["docs", "--head", "missing-ref"]) == 1
    assert "qualified_references:" in capsys.readouterr().err
