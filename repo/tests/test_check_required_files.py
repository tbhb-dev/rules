# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for the required files check."""

import json
import tomllib
from pathlib import Path
from unittest.mock import Mock

import pytest

from repo.tests import check_required_files as checker

# Most tests use a reduced schema to isolate declaration validation.
# The shell tests and baseline test use the real repo.schema.json.
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
                    "required": ["check", "path", "reason"],
                    "properties": {
                        "check": {"type": "string"},
                        "path": {"type": "string", "minLength": 1},
                        "reason": {"type": "string", "pattern": "\\S"},
                    },
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


def assert_main_output(  # noqa: PLR0913 -- Fixtures and output assertions.
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    expected: str,
    status: int = 1,
    *,
    prefix: bool = False,
) -> None:
    assert (
        checker.main([str(manifest), str(manifest.with_name("schema.json")), str(repo)])
        == status
    )
    captured = capsys.readouterr()
    if prefix:
        assert captured.out.startswith(expected)
        assert len(captured.out.splitlines()) == 1
    else:
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
        f"{manifest}: visibility must be a table\n",
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
        f"{manifest}: kind must be a table\n",
    )


def test_invalid_utf8(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (repo / ".tbhb-repo.toml").write_bytes(b"\xff")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{repo / '.tbhb-repo.toml'}: invalid TOML:",
        prefix=True,
    )


@pytest.mark.parametrize("value", ["''", "1", "true", "{}"])
@pytest.mark.parametrize(("table", "name"), [("kind", "go"), ("visibility", "public")])
def test_required_not_list(  # noqa: PLR0913, PLR0917 -- Fixtures and parameters.
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    name: str,
    value: str,
) -> None:
    declare(repo, "")
    manifest.write_text(
        "[kind.go]\nrequired = []\n[visibility.public]\nrequired = []\n".replace(
            f"[{table}.{name}]\nrequired = []",
            f"[{table}.{name}]\nrequired = {value}",
        )
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


@pytest.mark.parametrize("value", ["1", "[]", "'go'"])
@pytest.mark.parametrize(
    ("table", "other"),
    [("kind", "[visibility.public]"), ("visibility", "[kind.go]")],
)
def test_table_of_wrong_type(  # noqa: PLR0913, PLR0917 -- Fixtures and parameters.
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    other: str,
    value: str,
) -> None:
    declare(repo, "")
    manifest.write_text(f"{table} = {value}\n{other}\nrequired = []\n")
    assert_main_output(manifest, repo, capsys, f"{manifest}: {table} must be a table\n")


@pytest.mark.parametrize("value", ["1", "[]", "'go'"])
@pytest.mark.parametrize(("table", "name"), [("kind", "go"), ("visibility", "public")])
def test_entry_of_wrong_type(  # noqa: PLR0913, PLR0917 -- Fixtures and parameters.
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    name: str,
    value: str,
) -> None:
    declare(repo, "")
    manifest.write_text(
        "[kind.go]\nrequired = []\n[visibility.public]\nrequired = []\n".replace(
            f"[{table}.{name}]\nrequired = []", f"[{table}]\n{name} = {value}"
        )
    )
    assert_main_output(
        manifest, repo, capsys, f'{manifest}: {table} "{name}" must be a table\n'
    )


@pytest.mark.parametrize(
    "path",
    [
        "/etc/hostname",
        "/",
        "..",
        "../go.mod",
        "cmd/..",
        "cmd/../go.mod",
        "",
        ".",
        "./",
        "a\nb",
        "a\n/../go.mod",
        "a\rb",
        "a\\b",
        "C:go.mod",
        "z:/go.mod",
        "a\x00b",
    ],
)
@pytest.mark.parametrize(("table", "name"), [("kind", "go"), ("visibility", "public")])
def test_required_path_outside_repository(  # noqa: PLR0913, PLR0917 -- Fixtures and parameters.
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    table: str,
    name: str,
    path: str,
) -> None:
    declare(repo, "")
    populate(repo)
    manifest.write_text(
        "[kind.go]\nrequired = []\n[visibility.public]\nrequired = []\n".replace(
            f"[{table}.{name}]\nrequired = []",
            f"[{table}.{name}]\nrequired = ['go.mod', {json.dumps(path)}]",
        )
    )
    assert_main_output(
        manifest,
        repo,
        capsys,
        f'{manifest}: {table} "{name}" required path {path!r} '
        "must be a safe relative path\n",
    )


@pytest.mark.parametrize(
    "path",
    ["..rc", "rc..", "a..b", "...", "cmd/..rc", "cmd/rc..", "cmd/.../x", "a/b/c"],
)
def test_required_path_with_dots_inside_repository(
    manifest: Path, repo: Path, path: str
) -> None:
    declare(repo, "")
    populate(repo)
    (repo / path).parent.mkdir(parents=True, exist_ok=True)
    (repo / path).write_text("")
    manifest.write_text(
        f"[kind.go]\nrequired = ['{path}']\n"
        f"[visibility.public]\nrequired = ['{path}']\n"
    )
    assert run(manifest, repo) == []


def test_manifest_invalid_toml(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_text("kind =")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{manifest}: invalid TOML:",
        prefix=True,
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
        "manifest or schema: cannot read UTF-8\n",
        status=2,
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
        f"{schema}: invalid schema: invalid JSON:",
        status=2,
        prefix=True,
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
        "manifest or schema: cannot read UTF-8\n",
        status=2,
    )


def test_other_exception(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(
        repo,
        "[[exception]]\ncheck = 'C8'\npath = 'go.mod'\nreason = 'Other check.'\n"
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
        f"{repo / '.tbhb-repo.toml'}: $.exception[0]:",
        prefix=True,
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
        f"{repo / '.tbhb-repo.toml'}: $.exception[0]:",
        prefix=True,
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
        ("schema_version = 1\nkind = 'go'\n", "$:"),
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


def test_stale_exceptions_are_sorted(manifest: Path, repo: Path) -> None:
    declare(
        repo,
        "".join(
            f"[[exception]]\ncheck = 'C4'\npath = '{name}'\nreason = 'Stale.'\n"
            for name in ("c", "a", "b")
        ),
    )
    populate(repo)
    assert run(manifest, repo) == [
        f"{repo / '.tbhb-repo.toml'}: exception for {name} but it is not missing"
        for name in ("a", "b", "c")
    ]


def test_missing_manifest_is_unusable(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.unlink()
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{manifest}: cannot read:",
        status=2,
        prefix=True,
    )


def test_missing_schema_is_unusable(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    schema.unlink()
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{schema}: cannot read:",
        status=2,
        prefix=True,
    )


def test_schema_that_is_not_a_schema_is_unusable(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    schema.write_text('{"type": 5}')
    assert checker.main([str(manifest), str(schema), str(repo)]) == checker.UNUSABLE
    captured = capsys.readouterr()
    assert captured.out.startswith(f"{schema}: invalid schema:")
    assert len(captured.out.splitlines()) == 1
    assert captured.err == ""


@pytest.mark.parametrize(
    "reference", ["#/$defs/missing", "https://example.invalid/x.json"]
)
def test_unresolvable_schema_reference(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
    reference: str,
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    data = json.loads(SCHEMA_TEXT)
    data["$ref"] = reference
    retrieve = Mock(side_effect=AssertionError("network access"))
    monkeypatch.setattr("urllib.request.urlopen", retrieve)
    schema.write_text(json.dumps(data))
    assert_main_output(
        manifest, repo, capsys, f"{schema}: invalid schema: ", status=2, prefix=True
    )
    retrieve.assert_not_called()


def test_recursive_schema_reference(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    data = json.loads(SCHEMA_TEXT)
    data["$ref"] = "#"
    schema.write_text(json.dumps(data))
    assert_main_output(
        manifest, repo, capsys, f"{schema}: invalid schema: ", status=2, prefix=True
    )


def test_unresolvable_reference_diagnostic(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    declare(repo, "")
    error = checker.Unresolvable(ref="missing\nreference")
    monkeypatch.setattr(checker.Draft202012Validator, "check_schema", Mock())
    monkeypatch.setattr(
        checker.Draft202012Validator, "iter_errors", Mock(side_effect=error)
    )
    schema = manifest.with_name("schema.json")
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{schema}: invalid schema: {str(error).splitlines()[0]}\n",
        status=2,
    )


BASELINE = Path(__file__).parents[1] / "baseline"


@pytest.mark.parametrize("visibility", ["public", "private"])
def test_real_manifest_resolves_every_kind(repo: Path, visibility: str) -> None:
    kinds = json.loads((BASELINE / "repo.schema.json").read_bytes())["properties"][
        "kind"
    ]["enum"]
    assert kinds
    for kind in kinds:
        errors = checker.check_manifest(
            BASELINE / "manifest.toml", repo, kind, visibility, []
        )
        # An empty repository lacks every path, so each line names a missing
        # path; any other line means the manifest and the check disagree.
        assert errors
        assert all(error.endswith(" is missing") for error in errors)
        assert f"{repo}: required file .tbhb-repo.toml is missing" in errors


@pytest.mark.parametrize("declaration", [None, "kind =", "kind = 'go'\n"])
@pytest.mark.parametrize("input_name", ["manifest.toml", "schema.json"])
@pytest.mark.parametrize("failure", ["missing", "oserror", "utf8"])
def test_unreadable_input_precedes_declaration(  # noqa: PLR0913, PLR0917 -- Input matrix.
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    declaration: str | None,
    input_name: str,
    failure: str,
) -> None:
    if declaration is not None:
        (repo / ".tbhb-repo.toml").write_text(declaration)
    path = manifest.with_name(input_name)
    path.unlink()
    if failure == "oserror":
        path.mkdir()
    elif failure == "utf8":
        path.write_bytes(b"\xff")
    assert_main_output(
        manifest,
        repo,
        capsys,
        "manifest or schema: cannot read UTF-8"
        if failure == "utf8"
        else f"{path}: cannot read:",
        status=2,
        prefix=True,
    )


@pytest.mark.parametrize("declaration", [None, "kind =", "kind = 'go'\n"])
@pytest.mark.parametrize("schema_text", ["{", "{}", "true", '{"type": "object"}'])
def test_bad_schema_precedes_declaration(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    declaration: str | None,
    schema_text: str,
) -> None:
    if declaration is not None:
        (repo / ".tbhb-repo.toml").write_text(declaration)
    schema = manifest.with_name("schema.json")
    schema.write_text(schema_text)
    assert_main_output(
        manifest, repo, capsys, f"{schema}: invalid schema:", status=2, prefix=True
    )


@pytest.mark.parametrize(
    "data",
    [
        {"type": "array"},
        {"type": "object", "required": ["kind", "private"]},
        {"type": "object", "required": ["kind", "private"], "properties": {}},
        {
            "type": "object",
            "required": ["kind", "private"],
            "properties": {"kind": True, "private": True},
        },
        {
            "type": "object",
            "required": ["kind", "private"],
            "properties": {"kind": {}, "private": {"type": "boolean"}},
        },
        {
            "type": "object",
            "required": ["kind", "private"],
            "properties": {"kind": {"type": "string"}, "private": {"type": "string"}},
        },
    ],
)
def test_schema_contract(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    data: object,
) -> None:
    declare(repo, "")
    schema = manifest.with_name("schema.json")
    schema.write_text(json.dumps(data))
    assert_main_output(
        manifest, repo, capsys, f"{schema}: invalid schema:", status=2, prefix=True
    )


def test_string_kind_schema(manifest: Path, repo: Path) -> None:
    declare(repo, "")
    populate(repo)
    data = json.loads(SCHEMA_TEXT)
    data["properties"]["kind"] = {"type": "string"}
    manifest.with_name("schema.json").write_text(json.dumps(data))
    assert run(manifest, repo) == []


@pytest.mark.parametrize(
    "input_name", ["manifest.toml", "schema.json", ".tbhb-repo.toml"]
)
def test_oserror_without_filename(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
    input_name: str,
) -> None:
    declare(repo, "")
    original = Path.read_bytes

    def refuse(path: Path) -> bytes:
        if path.name == input_name:
            msg = "read failed"
            raise OSError(msg)
        return original(path)

    monkeypatch.setattr(Path, "read_bytes", refuse)
    assert_main_output(manifest, repo, capsys, "cannot read:", status=2, prefix=True)


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("path", None),
        ("path", 1),
        ("path", ""),
        ("reason", None),
        ("reason", 1),
        ("reason", ""),
        ("reason", " "),
    ],
)
def test_c4_helper_rejects_bad_fields(key: str, value: object) -> None:
    entry: dict[str, object] = {"check": "C4", "path": "go.mod", "reason": "Needed."}
    if value is None:
        entry.pop(key)
    else:
        entry[key] = value
    assert checker.c4_exception_paths([entry]) is None
    assert checker.check_paths(Path("repo"), [], [entry]) == [
        f"{Path('repo') / '.tbhb-repo.toml'}: C4 exception needs a path and a reason"
    ]


def test_c4_helper_ignores_other_checks() -> None:
    assert checker.c4_exception_paths([{}, {"check": "C8"}]) == set()


def test_empty_manifest(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    manifest.write_text("")
    assert_main_output(manifest, repo, capsys, f"{manifest}: kind must be a table\n")


def test_real_manifest_check_and_main(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    manifest = BASELINE / "manifest.toml"
    schema = BASELINE / "repo.schema.json"
    declare(repo, "")
    errors = checker.check(manifest, schema, repo)
    assert errors
    assert all(error.endswith(" is missing") for error in errors)
    assert checker.main([str(manifest), str(schema), str(repo)]) == 1
    assert capsys.readouterr().out == "".join(f"{error}\n" for error in errors)
    rules = tomllib.loads(manifest.read_text())
    for path in (
        rules["kind"]["go"]["required"] + rules["visibility"]["public"]["required"]
    ):
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.touch()
    assert checker.check(manifest, schema, repo) == []
    assert checker.main([str(manifest), str(schema), str(repo)]) == 0
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("content", [b"kind =", b"\xff"])
def test_check_manifest_invalid_toml(
    manifest: Path, repo: Path, content: bytes
) -> None:
    manifest.write_bytes(content)
    errors = checker.check_manifest(manifest, repo, "go", "public", [])
    assert len(errors) == 1
    assert errors[0].startswith(f"{manifest}: invalid TOML:")


@pytest.mark.parametrize("data", [True, {}, {"type": "array"}])
def test_schema_contract_needs_object(data: object) -> None:
    with pytest.raises(
        checker.SchemaError, match=r"^schema must define an object declaration$"
    ):
        checker.validate_schema_contract(data)


@pytest.mark.parametrize(
    ("required", "properties"),
    [
        (None, {}),
        ([], {}),
        (["kind"], {}),
        (["private"], {}),
        (["kind", "private"], None),
    ],
)
def test_schema_contract_needs_fields(required: object, properties: object) -> None:
    with pytest.raises(
        checker.SchemaError, match=r"^schema must require and define kind and private$"
    ):
        checker.validate_schema_contract(
            {"type": "object", "required": required, "properties": properties}
        )


@pytest.mark.parametrize(("kind", "private"), [(None, {}), ({}, None), (True, {})])
def test_schema_contract_needs_property_schemas(kind: object, private: object) -> None:
    with pytest.raises(
        checker.SchemaError, match=r"^schema must define kind and private$"
    ):
        checker.validate_schema_contract(
            {
                "type": "object",
                "required": ["kind", "private"],
                "properties": {"kind": kind, "private": private},
            }
        )


@pytest.mark.parametrize(
    ("kind", "private"),
    [
        ({}, {"type": "boolean"}),
        ({"enum": []}, {"type": "boolean"}),
        ({"enum": [1]}, {"type": "boolean"}),
        ({"type": "string"}, {}),
        ({"enum": ["go"]}, {"type": "string"}),
    ],
)
def test_schema_contract_needs_field_types(kind: object, private: object) -> None:
    with pytest.raises(
        checker.SchemaError,
        match=r"^schema must constrain kind to strings and private to booleans$",
    ):
        checker.validate_schema_contract(
            {
                "type": "object",
                "required": ["kind", "private"],
                "properties": {"kind": kind, "private": private},
            }
        )


@pytest.mark.parametrize(
    "exception",
    [
        None,
        True,
        {},
        {"type": "object"},
        {"type": "array"},
        {"type": "array", "items": True},
        {"type": "array", "items": {}},
        {"type": "array", "items": {"type": "string"}},
    ],
)
def test_schema_needs_exception_objects(
    manifest: Path,
    repo: Path,
    capsys: pytest.CaptureFixture[str],
    exception: object,
) -> None:
    declare(repo, "")
    data = json.loads(SCHEMA_TEXT)
    if exception is None:
        del data["properties"]["exception"]
    else:
        data["properties"]["exception"] = exception
    manifest.with_name("schema.json").write_text(json.dumps(data))
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{manifest.with_name('schema.json')}: invalid schema: "
        "schema must define exception as an array of objects\n",
        status=2,
    )


def test_invalid_nested_schema(
    manifest: Path, repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(repo, "")
    data = json.loads(SCHEMA_TEXT)
    data["properties"]["unused"] = {"type": 5}
    manifest.with_name("schema.json").write_text(json.dumps(data))
    assert_main_output(
        manifest,
        repo,
        capsys,
        f"{manifest.with_name('schema.json')}: invalid schema:",
        status=2,
        prefix=True,
    )


def test_check_manifest_bad_table(manifest: Path, repo: Path) -> None:
    manifest.write_text("kind = 1\n")
    assert checker.check_manifest(manifest, repo, "go", "public", []) == [
        f"{manifest}: kind must be a table"
    ]


def test_exception_path_keeps_spaces(manifest: Path, repo: Path) -> None:
    declare(repo, "[[exception]]\ncheck = 'C4'\npath = ' '\nreason = 'Needed.'\n")
    manifest.write_text(
        "[kind.go]\nrequired = [' ']\n[visibility.public]\nrequired = []\n"
    )
    assert checker.c4_exception_paths(
        [{"check": "C4", "path": " ", "reason": "Needed."}]
    ) == {" "}
    assert run(manifest, repo) == []
