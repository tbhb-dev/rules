# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for decision record names, numbers, and replacement references."""

import sys
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from lint.private.decision_records import check_decisions


def write(root: Path, names: list[str], directory: str = "docs/decisions") -> None:
    folder = root / directory
    folder.mkdir(parents=True, exist_ok=True)
    for name in names:
        # Unreadable frontmatter belongs to okf_docs_test.
        (folder / name).write_bytes(b"---\n\xff\n")


def test_missing_directory_passes(tmp_path: Path) -> None:
    assert check_decisions.check(tmp_path) == []


def test_empty_directory_passes(tmp_path: Path) -> None:
    write(tmp_path, [])
    assert check_decisions.check(tmp_path) == []


def test_directory_must_be_a_directory(tmp_path: Path) -> None:
    (tmp_path / "records").write_text("a file", encoding="utf-8")
    assert check_decisions.check(tmp_path, "records") == ["records: not a directory"]


def test_valid_filenames_and_exempt_files(tmp_path: Path) -> None:
    write(
        tmp_path,
        [
            "9999-use-2-stores.md",
            "0000-a.md",
            "0001-9.md",
            "index.md",
            "AGENTS.md",
            "CLAUDE.md",
        ],
    )
    assert check_decisions.check(tmp_path) == []


@pytest.mark.parametrize(
    "name",
    [
        "1-short.md",
        "001-short.md",
        "00001-long.md",
        "0001-.md",
        "0001--leading.md",
        "0001-trailing-.md",
        "0001-two--hyphens.md",
        "0001-Upper.md",
        "0001-under_score.md",
        "0001-with space.md",
        "0001-café.md",
        "0001-a.b.md",
        "prefix-0001-a.md",
        "0001-a.md.md",
        "INDEX.md",
        "agents.md",
        "claude.md",
        ".hidden.md",
    ],
)
def test_bad_markdown_filename(tmp_path: Path, name: str) -> None:
    write(tmp_path, [name])
    assert check_decisions.check(tmp_path) == [
        f"docs/decisions/{name}: expected NNNN-<slug>.md"
    ]


@pytest.mark.parametrize("name", ["notes.txt", "0001-a.MD", "0001-a", ".keep"])
def test_non_markdown_file(tmp_path: Path, name: str) -> None:
    write(tmp_path, [name])
    assert check_decisions.check(tmp_path) == [
        f"docs/decisions/{name}: expected a Markdown file"
    ]


def test_stray_entries_do_not_stop_the_scan(tmp_path: Path) -> None:
    write(tmp_path, ["a.txt", "z.md"])
    write(tmp_path, ["child.md"], "docs/decisions/nested")
    assert check_decisions.check(tmp_path) == [
        "docs/decisions/a.txt: expected a Markdown file",
        "docs/decisions/nested: expected a Markdown file",
        "docs/decisions/z.md: expected NNNN-<slug>.md",
    ]


@pytest.mark.parametrize("name", ["AGENTS.md", "CLAUDE.md", "index.md"])
def test_exempt_files_do_not_stop_the_scan(tmp_path: Path, name: str) -> None:
    write(tmp_path, [name, "z.md"])
    assert check_decisions.check(tmp_path) == [
        "docs/decisions/z.md: expected NNNN-<slug>.md"
    ]


@pytest.mark.parametrize(
    "name", ["nested", "0001-a.md", "index.md", "AGENTS.md", "CLAUDE.md"]
)
def test_subdirectory_is_reported_once_without_recursing(
    tmp_path: Path, name: str
) -> None:
    write(tmp_path, ["bad.md"], f"docs/decisions/{name}")
    assert check_decisions.check(tmp_path) == [
        f"docs/decisions/{name}: expected a Markdown file"
    ]


def test_duplicate_number_names_both_paths_once(tmp_path: Path) -> None:
    write(tmp_path, ["0000-z.md", "0001-a.md", "0000-a.md"])
    assert check_decisions.check(tmp_path) == [
        "docs/decisions/0000-z.md: duplicate number 0000 with docs/decisions/0000-a.md"
    ]


def test_every_collision_names_the_first_path(tmp_path: Path) -> None:
    write(tmp_path, ["0001-c.md", "0001-b.md", "0001-a.md", "0002-a.md", "bad.md"])
    assert check_decisions.check(tmp_path) == [
        "docs/decisions/0001-b.md: duplicate number 0001 with docs/decisions/0001-a.md",
        "docs/decisions/0001-c.md: duplicate number 0001 with docs/decisions/0001-a.md",
        "docs/decisions/bad.md: expected NNNN-<slug>.md",
    ]


# Windows filesystem latency can exceed Hypothesis's default deadline.
@settings(deadline=None)
@given(
    st.dictionaries(
        st.integers(min_value=0, max_value=9999),
        st.lists(
            st.text(
                alphabet="abcdefghijklmnopqrstuvwxyz0123456789", min_size=1, max_size=8
            ),
            min_size=1,
            max_size=4,
        ),
        min_size=1,
        max_size=10,
    )
)
def test_distinct_numbers_and_kebab_case_slugs_pass(
    records: dict[int, list[str]],
) -> None:
    with TemporaryDirectory() as directory:
        root = Path(directory)
        write(
            root,
            [f"{number:04d}-{'-'.join(words)}.md" for number, words in records.items()],
        )
        assert check_decisions.check(root) == []


def test_another_directory_ignores_default_location(tmp_path: Path) -> None:
    write(tmp_path, ["bad.md"])
    write(tmp_path, ["0001-a.md"], "book/records")
    assert check_decisions.check(tmp_path, "book/records") == []


def test_main_reports_ok(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    write(tmp_path, ["0000-a.md"])
    assert check_decisions.main([str(tmp_path)]) == 0
    assert (
        capsys.readouterr().out
        == "OK: decision record filenames, numbers, and replacements conform\n"
    )


def test_main_prints_every_error_and_fails(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, ["b.md", "a.md"])
    assert check_decisions.main([str(tmp_path)]) == 1
    assert capsys.readouterr().out == (
        "docs/decisions/a.md: expected NNNN-<slug>.md\n"
        "docs/decisions/b.md: expected NNNN-<slug>.md\n"
    )


def test_main_defaults_to_current_directory_and_argv(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    write(tmp_path, ["bad.md"])
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["check_decisions.py"])
    assert check_decisions.main() == 1
    assert capsys.readouterr().out == "docs/decisions/bad.md: expected NNNN-<slug>.md\n"


def test_main_takes_another_directory(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, ["0001-a.md"])
    write(tmp_path, ["bad.md"], "book/records")
    assert check_decisions.main(["--directory", "book/records", str(tmp_path)]) == 1
    assert capsys.readouterr().out == "book/records/bad.md: expected NNNN-<slug>.md\n"


def test_main_help_describes_the_tool(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as caught:
        check_decisions.main(["--help"])
    assert caught.value.code == 0
    out = " ".join(capsys.readouterr().out.split())
    assert " Check decision record filenames and replacements. " in out
    assert "--directory DIRECTORY the decision records directory, under ROOT" in out


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("---\nsuperseded_by: 2\n---\nBody", 2),
        ("---\nsuperseded_by: 0\n---", 0),
        ("---\nsuperseded_by: -1\n--- \t\n", -1),
        ("---\ndecided: 2026-11-09\nsuperseded_by: 12\n---\n", 12),
        ("---\n---\n", None),
        ("---\nnull\n---\n", None),
        ("---\n42\n---\n", None),
        ("---\n[superseded_by, 2]\n---\n", None),
        ("---\nstatus: deprecated\n---\n", None),
        ("---\nsuperseded_by: null\n---\n", None),
        ("---\nsuperseded_by: true\n---\n", None),
        ("---\nsuperseded_by: 2.5\n---\n", None),
        ('---\nsuperseded_by: "2"\n---\n', None),
        ("---\nsuperseded_by: [2]\n---\n", None),
        ("---\nsuperseded_by: {a: 2}\n---\n", None),
        ("---\nsuperseded_by: [\n---\n", None),
        ("---\nsuperseded_by: 2\n", None),
        ("Text\n---\nsuperseded_by: 2\n---\n", None),
        ("---\nstatus: stable\n---\nsuperseded_by: 2\n", None),
        ("---\ndecided: 2026-02-30\nsuperseded_by: 2\n---\n", None),
    ],
)
def test_replacement_reads_only_integer_frontmatter(
    tmp_path: Path, text: str, expected: int | None
) -> None:
    path = tmp_path / "record.md"
    path.write_text(text, encoding="utf-8")
    actual = check_decisions.replacement(path)
    assert actual == expected
    assert type(actual) is type(expected)


def test_replacement_ignores_invalid_utf8(tmp_path: Path) -> None:
    path = tmp_path / "record.md"
    path.write_bytes(b"---\nsuperseded_by: 2\n---\n\xff")
    assert check_decisions.replacement(path) is None


def test_replacement_ignores_read_error(tmp_path: Path) -> None:
    assert check_decisions.replacement(tmp_path / "missing.md") is None


def record(
    root: Path, name: str, target: int, directory: str = "docs/decisions"
) -> None:
    write(root, [name], directory)
    (root / directory / name).write_text(
        f"---\nsuperseded_by: {target}\n---\n", encoding="utf-8"
    )


def test_replacements_can_point_forward_and_backward_including_zero(
    tmp_path: Path,
) -> None:
    record(tmp_path, "0000-first.md", 42)
    record(tmp_path, "0042-next.md", 0)
    assert check_decisions.check(tmp_path) == []


@pytest.mark.parametrize("target", [-1, 2, 10000])
def test_replacement_must_exist(tmp_path: Path, target: int) -> None:
    record(tmp_path, "0001-first.md", target)
    assert check_decisions.check(tmp_path) == [
        f"docs/decisions/0001-first.md: superseded_by {target} names no record"
    ]


@pytest.mark.parametrize("number", [0, 1, 9999])
def test_record_cannot_name_itself(tmp_path: Path, number: int) -> None:
    name = f"{number:04d}-record.md"
    record(tmp_path, name, number)
    assert check_decisions.check(tmp_path) == [
        f"docs/decisions/{name}: superseded_by names itself"
    ]


def test_replacement_uses_only_records_in_the_same_directory(tmp_path: Path) -> None:
    record(tmp_path, "0001-first.md", 2, "records")
    write(tmp_path, ["0002-other.md"])
    assert check_decisions.check(tmp_path, "records") == [
        "records/0001-first.md: superseded_by 2 names no record"
    ]
    write(tmp_path, ["0002-replacement.md"], "records")
    assert check_decisions.check(tmp_path, "records") == []


def test_invalid_names_do_not_count_as_replacement_targets(tmp_path: Path) -> None:
    record(tmp_path, "0001-first.md", 2)
    write(tmp_path, ["0002-Upper.md"])
    assert check_decisions.check(tmp_path) == [
        "docs/decisions/0002-Upper.md: expected NNNN-<slug>.md",
        "docs/decisions/0001-first.md: superseded_by 2 names no record",
    ]


@pytest.mark.parametrize("name", ["bad.md", "index.md", "AGENTS.md", "CLAUDE.md"])
def test_references_are_checked_only_for_valid_record_names(
    tmp_path: Path, name: str
) -> None:
    record(tmp_path, name, 99)
    expected = (
        ["docs/decisions/bad.md: expected NNNN-<slug>.md"] if name == "bad.md" else []
    )
    assert check_decisions.check(tmp_path) == expected


def test_duplicate_records_still_have_their_references_checked(tmp_path: Path) -> None:
    record(tmp_path, "0001-a.md", 1)
    record(tmp_path, "0001-b.md", 9)
    assert check_decisions.check(tmp_path) == [
        "docs/decisions/0001-b.md: duplicate number 0001 with docs/decisions/0001-a.md",
        "docs/decisions/0001-a.md: superseded_by names itself",
        "docs/decisions/0001-b.md: superseded_by 9 names no record",
    ]


def test_main_reports_reference_errors(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    record(tmp_path, "0001-a.md", 9)
    record(tmp_path, "0002-b.md", 2)
    assert check_decisions.main([str(tmp_path)]) == 1
    assert capsys.readouterr().out == (
        "docs/decisions/0001-a.md: superseded_by 9 names no record\n"
        "docs/decisions/0002-b.md: superseded_by names itself\n"
    )
