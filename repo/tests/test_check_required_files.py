# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for the required files check."""

import json
lazy from pathlib import Path

import pytest

from repo.tests import check_required_files as checker

# The mutation run copies no baseline files, so the tests use a reduced schema.
# The shell tests run the real repo.schema.json.
SCHEMA_TEXT = json.dumps(
    {
        "type": "object",
        "required": ["schema_version", "kind", "private"],
        "properties": {
            "kind": {"enum": ["go", "docs"]},
            "private": {"type": "boolean"},
            "exception": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {"reason": {"type": "string", "pattern": "\\S"}},
                },
            },
        },
    }
)
MANIFEST_TEXT = (
    "[kind.go]\nrequired = ['go.mod', 'cmd/']\n"
    "[visibility.public]\nrequired = ['LICENSE', 'go.mod']\n"
    "[visibility.private]\nrequired = ['PRIVATE']\n"
)


@pytest.fixture
def manifest(tmp_path: Path) -> Path:
    path = tmp_path / "manifest.toml"
    path.write_text(MANIFEST_TEXT)
    (tmp_path / "schema.json").write_text(SCHEMA_TEXT)
    return path


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    return root


def declare(repo: Path, text: str) -> None:
    (repo / ".tbhb-repo.toml").write_text(
        f"schema_version = 1\nkind = 'go'\nprivate = false\n{text}"
    )


def populate(repo: Path) -> None:
    for name in ("go.mod", "LICENSE"):
        (repo / name).write_text("")
    (repo / "cmd").mkdir()


def run(manifest: Path, repo: Path) -> list[str]:
    return checker.check(manifest, manifest.with_name("schema.json"), repo)


def test_clean(manifest: Path, repo: Path) -> None:
    declare(repo, "")
    populate(repo)
    assert run(manifest, repo) == []


def test_missing_declaration(manifest: Path, repo: Path) -> None:
    assert run(manifest, repo) == [f"{repo / '.tbhb-repo.toml'}: missing"]


def test_invalid_toml(manifest: Path, repo: Path) -> None:
    (repo / ".tbhb-repo.toml").write_text("kind =")
    (error,) = run(manifest, repo)
    assert "invalid TOML" in error


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("schema_version = 1\nkind = 'rust'\nprivate = false\n", "$.kind"),
        ("schema_version = 1\nkind = 'go'\nprivate = 'no'\n", "$.private"),
        ("schema_version = 1\nkind = 'go'\n", "'private' is a required"),
        (
            (
                "schema_version = 1\nkind = 'go'\nprivate = false\n"
                "[[exception]]\ncheck = 'C4'\npath = 'go.mod'\nreason = ' '\n"
            ),
            "$.exception[0].reason",
        ),
    ],
)
def test_invalid_declaration(
    manifest: Path, repo: Path, text: str, expected: str
) -> None:
    (repo / ".tbhb-repo.toml").write_text(text)
    errors = run(manifest, repo)
    assert len(errors) == 1
    assert expected in errors[0]


def test_reports_each_missing_path(manifest: Path, repo: Path) -> None:
    declare(repo, "")
    (repo / "cmd").write_text("a file, not a directory")
    assert run(manifest, repo) == [
        f"{repo}: required file go.mod is missing",
        f"{repo}: required directory cmd/ is missing",
        f"{repo}: required file LICENSE is missing",
    ]


def test_directory_is_not_a_file(manifest: Path, repo: Path) -> None:
    declare(repo, "")
    populate(repo)
    (repo / "LICENSE").unlink()
    (repo / "LICENSE").mkdir()
    assert run(manifest, repo) == [f"{repo}: required file LICENSE is missing"]


def test_private_uses_private_list(manifest: Path, repo: Path) -> None:
    (repo / ".tbhb-repo.toml").write_text(
        "schema_version = 1\nkind = 'go'\nprivate = true\n"
    )
    (repo / "go.mod").write_text("")
    (repo / "cmd").mkdir()
    assert run(manifest, repo) == [f"{repo}: required file PRIVATE is missing"]


def test_exception_hides_one_missing_path(manifest: Path, repo: Path) -> None:
    declare(
        repo,
        "[[exception]]\ncheck = 'C4'\npath = 'LICENSE'\nreason = 'Not yet.'\n"
        "[[exception]]\ncheck = 'C8'\npath = 'go.mod'\nreason = 'Other check.'\n",
    )
    (repo / "go.mod").write_text("")
    (repo / "cmd").mkdir()
    assert run(manifest, repo) == []


def test_exception_for_present_path_fails(manifest: Path, repo: Path) -> None:
    declare(
        repo,
        "[[exception]]\ncheck = 'C4'\npath = 'go.mod'\nreason = 'Nothing differs.'\n",
    )
    populate(repo)
    assert run(manifest, repo) == [
        f"{repo / '.tbhb-repo.toml'}: exception for go.mod but it is not missing"
    ]


def test_main_exit_codes(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    populate(repo)
    assert (
        checker.main([str(manifest), str(manifest.with_name("schema.json")), str(repo)])
        == 0
    )
    assert not capsys.readouterr().out
    (repo / "go.mod").unlink()
    (repo / "LICENSE").unlink()
    assert (
        checker.main([str(manifest), str(manifest.with_name("schema.json")), str(repo)])
        == 1
    )
    assert capsys.readouterr().out == (
        f"{repo}: required file go.mod is missing\n"
        f"{repo}: required file LICENSE is missing\n"
    )
