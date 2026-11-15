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


def assert_main_output(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    expected: str,
    status: int = 1,
) -> None:
    assert (
        checker.main([str(manifest), str(manifest.with_name("schema.json")), str(repo)])
        == status
    )
    captured = capsys.readouterr()
    assert captured.out == expected
    assert captured.err == ""


def test_unknown_kind(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (repo / ".tbhb-repo.toml").write_text(
        "schema_version = 1\nkind = 'docs'\nprivate = false\n"
    )
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{repo / ".tbhb-repo.toml"}: kind "docs" has no entry in the manifest\n',
    )


def test_missing_visibility_table(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_text(
        "[kind.go]\nrequired = []\n[visibility.private]\nrequired = []\n"
    )
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{repo / ".tbhb-repo.toml"}: visibility "public" '
        "has no entry in the manifest\n",
    )


def test_missing_visibility_key(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_text("[kind.go]\nrequired = []\n")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{repo / ".tbhb-repo.toml"}: visibility "public" '
        "has no entry in the manifest\n",
    )


def test_missing_kind_key(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_text("[visibility.public]\nrequired = []\n")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{repo / ".tbhb-repo.toml"}: kind "go" has no entry in the manifest\n',
    )


def test_invalid_utf8(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (repo / ".tbhb-repo.toml").write_bytes(b"\xff")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{repo / '.tbhb-repo.toml'}: invalid TOML: "
        "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte\n",
    )


@pytest.mark.parametrize(("table", "name"), [("kind", "go"), ("visibility", "public")])
def test_required_string(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    name: str,
) -> None:
    declare(repo, "")
    manifest.write_text(
        "[kind.go]\nrequired = ''\n[visibility.public]\nrequired = ''\n"
        if table == "kind"
        else "[kind.go]\nrequired = []\n[visibility.public]\nrequired = ''\n"
    )
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{manifest}: {table} "{name}" needs a required list of strings\n',
    )


@pytest.mark.parametrize(("table", "name"), [("kind", "go"), ("visibility", "public")])
def test_required_non_string_item(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    name: str,
) -> None:
    declare(repo, "")
    manifest.write_text(
        "[kind.go]\nrequired = []\n[visibility.public]\nrequired = []\n".replace(
            f"[{table}.{name}]\nrequired = []",
            f"[{table}.{name}]\nrequired = ['ok', 1]",
        )
    )
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{manifest}: {table} "{name}" needs a required list of strings\n',
    )


@pytest.mark.parametrize(("table", "name"), [("kind", "go"), ("visibility", "public")])
def test_missing_required_key(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    name: str,
) -> None:
    declare(repo, "")
    manifest.write_text(
        "[kind.go]\nrequired = []\n[visibility.public]\nrequired = []\n".replace(
            f"[{table}.{name}]\nrequired = []", f"[{table}.{name}]"
        )
    )
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{manifest}: {table} "{name}" needs a required list of strings\n',
    )


def test_manifest_invalid_toml(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_text("kind =")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{manifest}: invalid TOML: Invalid value (at end of document)\n",
    )


def test_manifest_invalid_utf8(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_bytes(b"\xff")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{manifest}: invalid TOML: "
        "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte\n",
    )


def test_schema_invalid_json(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    schema.write_text("{")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{schema}: invalid JSON: "
        "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)\n",
    )


def test_schema_invalid_utf8(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    schema.write_bytes(b"\xff")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{schema}: invalid JSON: "
        "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte\n",
    )


def test_exception_without_check(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(
        repo,
        "[[exception]]\npath = 'go.mod'\nreason = 'Other check.'\n"
        "[[exception]]\ncheck = 'C4'\npath = 'LICENSE'\nreason = 'Not yet.'\n",
    )
    populate(repo)
    (repo / "go.mod").unlink()
    (repo / "LICENSE").unlink()
    assert_main_output(
        manifest, repo, capsys, f"{repo}: required file go.mod is missing\n"
    )


def test_c4_exception_without_reason(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "[[exception]]\ncheck = 'C4'\npath = 'go.mod'\n")
    populate(repo)
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{repo / '.tbhb-repo.toml'}: C4 exception needs a path and a reason\n",
    )


def test_c4_exception_without_path(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "[[exception]]\ncheck = 'C4'\nreason = 'Not yet.'\n")
    populate(repo)
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{repo / '.tbhb-repo.toml'}: C4 exception needs a path and a reason\n",
    )


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


def test_exception_hides_only_its_own_path(manifest: Path, repo: Path) -> None:
    declare(
        repo,
        "[[exception]]\ncheck = 'C4'\npath = 'LICENSE'\nreason = 'Not yet.'\n",
    )
    (repo / "cmd").mkdir()
    assert run(manifest, repo) == [f"{repo}: required file go.mod is missing"]


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


def symlink_or_skip(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target, target_is_directory=target.is_dir())
    except OSError, NotImplementedError:
        pytest.skip("this host cannot create symlinks")


def test_symlink_to_outside_file_is_missing(
    manifest: Path, repo: Path, tmp_path: Path
) -> None:
    declare(repo, "")
    populate(repo)
    outside = tmp_path / "outside.mod"
    outside.write_text("")
    (repo / "go.mod").unlink()
    symlink_or_skip(repo / "go.mod", outside)
    assert run(manifest, repo) == [f"{repo}: required file go.mod is missing"]


def test_symlink_to_outside_directory_is_missing(
    manifest: Path, repo: Path, tmp_path: Path
) -> None:
    declare(repo, "")
    populate(repo)
    outside = tmp_path / "outside"
    outside.mkdir()
    (repo / "cmd").rmdir()
    symlink_or_skip(repo / "cmd", outside)
    assert run(manifest, repo) == [f"{repo}: required directory cmd/ is missing"]


def test_symlink_inside_repo_is_present(manifest: Path, repo: Path) -> None:
    declare(repo, "")
    populate(repo)
    (repo / "real.mod").write_text("")
    (repo / "go.mod").unlink()
    symlink_or_skip(repo / "go.mod", repo / "real.mod")
    assert run(manifest, repo) == []


def test_symlink_helper_skips_when_unsupported(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def refuse(*_args: object, **_kwargs: object) -> None:
        raise OSError

    monkeypatch.setattr(Path, "symlink_to", refuse)
    with pytest.raises(pytest.skip.Exception):
        symlink_or_skip(tmp_path / "link", tmp_path)
