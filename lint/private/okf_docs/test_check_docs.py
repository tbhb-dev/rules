# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for the docs and frontmatter checker."""

import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

import pytest
import yaml
from hypothesis import assume, given
from hypothesis import strategies as st
from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError

from lint.private.okf_docs import check_docs

# mutmut runs the tests from a copy of the source tree, so the fixtures
# resolve against this file and the real schemas against the first ancestor
# that holds docs/schemas (the repository root, or the root above mutants/).
DATA = Path(__file__).parent / "testdata"
SCHEMAS = next(
    parent / "docs" / "schemas"
    for parent in Path(__file__).resolve().parents
    if (parent / "docs" / "schemas").is_dir()
)
CASES = json.loads((DATA / "frontmatter_cases.json").read_text(encoding="utf-8"))

FENCE = "---\n"
ROOT_INDEX = FENCE + 'okf_version: "0.2"\n' + FENCE + "\n## Docs\n\n"
DOC = (
    "---\ndescription: D\nstatus: stable\ntags: [a]\n"
    "title: T\ntype: Reference\n---\n\n# T\n"
)


def doc_validator() -> Draft202012Validator:
    return check_docs.load_validator(SCHEMAS / "frontmatter.schema.json")


def index_validator() -> Draft202012Validator:
    return check_docs.load_validator(SCHEMAS / "index-frontmatter.schema.json")


def write(root: Path, files: dict[str, str]) -> None:
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def make_repo(root: Path, files: dict[str, str]) -> Path:
    write(root, files)
    return root


def entry(link: str, title: str = "T") -> str:
    return f"* [{title}]({link}) - A doc.\n"


# parse


def test_parse_without_frontmatter() -> None:
    assert check_docs.parse("# Title\n") == (None, "# Title\n")


def test_parse_returns_data_and_body() -> None:
    text = "---\na: 1\nb: [x, y]\n---\n\nbody\n"
    assert check_docs.parse(text) == ({"a": 1, "b": ["x", "y"]}, "\nbody\n")


def test_parse_empty_block_is_none() -> None:
    assert check_docs.parse("---\n---\nbody") == (None, "body")


def test_parse_closing_fence_may_have_trailing_blanks() -> None:
    assert check_docs.parse("---\na: 1\n---  \nbody") == ({"a": 1}, "body")


def test_parse_closes_at_first_fence() -> None:
    assert check_docs.parse("---\na: 1\n---\nx\n---\ny\n") == ({"a": 1}, "x\n---\ny\n")


def test_parse_fence_must_start_the_line() -> None:
    with pytest.raises(
        check_docs.FrontmatterError, match=r"^unterminated frontmatter$"
    ):
        check_docs.parse("---\na: 1\n  ---\n")


def test_parse_fence_must_end_the_line() -> None:
    with pytest.raises(
        check_docs.FrontmatterError, match=r"^unterminated frontmatter$"
    ):
        check_docs.parse("---\na: 1\n----\n")


def test_parse_requires_opening_fence_on_first_line() -> None:
    assert check_docs.parse("\n---\na: 1\n---\n") == (None, "\n---\na: 1\n---\n")


def test_parse_unterminated() -> None:
    with pytest.raises(
        check_docs.FrontmatterError, match=r"^unterminated frontmatter$"
    ):
        check_docs.parse("---\na: 1\n")


def test_parse_invalid_yaml_message_is_one_line() -> None:
    with pytest.raises(check_docs.FrontmatterError) as caught:
        check_docs.parse("---\na: [1\n---\n")
    assert str(caught.value) == (
        "invalid YAML: while parsing a flow sequence "
        'in "<unicode string>", line 1, column 4: a: [1 ^ '
        "expected ',' or ']', but got '<stream end>' "
        'in "<unicode string>", line 2, column 1: ^'
    )
    assert isinstance(caught.value.__cause__, yaml.YAMLError)


def test_parse_keeps_timestamps_as_text_and_other_scalars_typed() -> None:
    text = "---\nat: 2026-11-02T09:30:00Z\nday: 2026-11-02\nn: 2\nok: true\n---\n"
    assert check_docs.parse(text)[0] == {
        "at": "2026-11-02T09:30:00Z",
        "day": "2026-11-02",
        "n": 2,
        "ok": True,
    }


_values = st.one_of(
    st.integers(), st.booleans(), st.text(alphabet="abc xyz-_.:,[]{}#'\"", max_size=12)
)


@given(
    data=st.dictionaries(
        st.text(alphabet="abcdefgh", min_size=1, max_size=6), _values, min_size=1
    ),
    body=st.text(alphabet="xyz \n#-", max_size=30),
)
def test_parse_round_trips_a_dumped_mapping(data: dict[str, object], body: str) -> None:
    text = "---\n" + yaml.safe_dump(data) + "---\n" + body
    assert check_docs.parse(text) == (data, body)


@given(st.text(max_size=60).filter(lambda text: not text.startswith("---\n")))
def test_parse_text_without_an_opening_fence_has_no_frontmatter(text: str) -> None:
    assert check_docs.parse(text) == (None, text)


# schemas


@pytest.mark.parametrize("name", ["frontmatter", "index-frontmatter"])
def test_schemas_are_valid_2020_12(name: str) -> None:
    schema = json.loads((SCHEMAS / f"{name}.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == (
        f"https://raw.githubusercontent.com/tbhb-dev/rules/main/docs/schemas/{name}.schema.json"
    )


@pytest.mark.parametrize("name", ["frontmatter", "index-frontmatter"])
def test_fixture_schemas_match_the_repository(name: str) -> None:
    root = SCHEMAS.parent.parent
    fixture = root / "lint/tests/okf_docs/testdata/tree/docs/schemas"
    assert (fixture / f"{name}.schema.json").read_bytes() == (
        SCHEMAS / f"{name}.schema.json"
    ).read_bytes()


def test_pull_request_draft_schema_id() -> None:
    path = SCHEMAS.parent.parent / ".github/schemas/pull-request-draft.schema.json"
    schema = json.loads(path.read_text(encoding="utf-8"))
    assert schema["$id"] == (
        "https://raw.githubusercontent.com/tbhb-dev/rules/main/"
        ".github/schemas/pull-request-draft.schema.json"
    )


def test_load_validator_rejects_an_invalid_schema(tmp_path: Path) -> None:
    (tmp_path / "bad.json").write_text('{"type": 5}', encoding="utf-8")
    with pytest.raises(SchemaError):
        check_docs.load_validator(tmp_path / "bad.json")


def test_load_validator_checks_formats(tmp_path: Path) -> None:
    (tmp_path / "f.json").write_text('{"format": "date-time"}', encoding="utf-8")
    validator = check_docs.load_validator(tmp_path / "f.json")
    assert check_docs.problems("2026-11-02T09:30:00Z", validator) == []
    assert check_docs.problems("soon", validator) == ["$: 'soon' is not a 'date-time'"]


@pytest.mark.parametrize("case", CASES["valid"], ids=lambda case: case["name"])
def test_valid_frontmatter(case: dict[str, object]) -> None:
    assert check_docs.problems(case["frontmatter"], doc_validator()) == []


@pytest.mark.parametrize("case", CASES["invalid"], ids=lambda case: case["name"])
def test_invalid_frontmatter(case: dict[str, object]) -> None:
    assert check_docs.problems(case["frontmatter"], doc_validator()) == case["errors"]


def test_missing_frontmatter_is_a_problem() -> None:
    assert check_docs.problems(None, doc_validator()) == ["no frontmatter"]


def test_non_mapping_frontmatter_is_a_problem() -> None:
    assert check_docs.problems(["a"], doc_validator()) == [
        "$: ['a'] is not of type 'object'"
    ]


def test_root_index_schema() -> None:
    assert check_docs.problems({"okf_version": "0.2"}, index_validator()) == []
    assert check_docs.problems({"okf_version": 0.2}, index_validator()) == [
        "$.okf_version: '0.2' was expected"
    ]
    assert check_docs.problems(
        {"okf_version": "0.2", "type": "Overview"}, index_validator()
    ) == ["$: Additional properties are not allowed ('type' was unexpected)"]
    assert check_docs.problems({}, index_validator()) == [
        "$: 'okf_version' is a required property"
    ]


def _pattern_strategy(name: str) -> st.SearchStrategy[str]:
    """Generate values for a contributor field from the schema's own pattern."""
    schema = json.loads(
        (SCHEMAS / "frontmatter.schema.json").read_text(encoding="utf-8")
    )
    field = schema["$defs"]["contributor"]["properties"][name]
    if "$ref" in field:
        field = schema["$defs"][field["$ref"].rsplit("/", 1)[1]]
    return st.from_regex(str(field["pattern"]), fullmatch=True)


_OPTIONAL = ["effort", "surface", "session", "subagent"]
_TIMESTAMPS = st.datetimes(
    min_value=datetime(1970, 1, 1)  # noqa: DTZ001, max_value=datetime(9999, 12, 31, 23, 59, 59)  # noqa: DTZ001
).map(lambda moment: moment.strftime("%Y-%m-%dT%H:%M:%SZ"))


@st.composite
def _contributors(draw: st.DrawFn) -> dict[str, str]:
    contributor = {
        "role": draw(st.sampled_from(["generated", "assisted"])),
        "harness": draw(_pattern_strategy("harness")),
        "model": draw(_pattern_strategy("model")),
        "at": draw(_TIMESTAMPS),
    }
    for name in _OPTIONAL:
        if draw(st.booleans()):
            contributor[name] = draw(_pattern_strategy(name))
    return contributor


def _document(contributor: dict[str, str]) -> dict[str, object]:
    return {
        "type": "Reference",
        "title": "T",
        "description": "D",
        "tags": ["t"],
        "status": "draft",
        "generated": [contributor],
    }


@given(_contributors())
def test_every_pattern_generated_value_is_accepted(contributor: dict[str, str]) -> None:
    assert check_docs.problems(_document(contributor), doc_validator()) == []


@given(
    _contributors(), st.sampled_from(["harness", "model", "session", "at", "effort"])
)
def test_a_trailing_space_breaks_a_contributor_field(
    contributor: dict[str, str], name: str
) -> None:
    assume(name in contributor)
    contributor[name] += " "
    assert check_docs.problems(_document(contributor), doc_validator()) != []


# bundle


def bundle(root: Path, files: dict[str, str]) -> list[str]:
    write(root, {f"docs/{name}": text for name, text in files.items()})
    return check_docs.check_bundle(
        root,
        doc_validator(),
        index_validator(),
    )


def test_conforming_bundle(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX
        + entry("a.md")
        + entry("sub/b.md")
        + "\nProse.\n- dash list\n",
        "a.md": DOC,
        "sub/b.md": DOC,
        "sub/index.md": "# Sub\n\n" + entry("b.md") + entry("../a.md"),
    }
    assert bundle(tmp_path, files) == []


def test_missing_root_index_and_unlisted_document(tmp_path: Path) -> None:
    assert bundle(tmp_path, {"a.md": DOC}) == [
        "docs/index.md: missing bundle-root index",
        "docs/a.md: not listed in any index.md",
    ]


def test_each_unlisted_document_is_reported(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX + entry("a.md"),
        "a.md": DOC,
        "b.md": DOC,
        "c.md": DOC,
    }
    assert bundle(tmp_path, files) == [
        "docs/b.md: not listed in any index.md",
        "docs/c.md: not listed in any index.md",
    ]


def test_document_problems_are_prefixed_with_the_path(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX + entry("a.md"),
        "a.md": "---\ntype: Reference\n---\n",
    }
    assert bundle(tmp_path, files) == [
        "docs/a.md: $: 'title' is a required property",
        "docs/a.md: $: 'description' is a required property",
        "docs/a.md: $: 'tags' is a required property",
        "docs/a.md: $: 'status' is a required property",
    ]


def test_document_without_frontmatter(tmp_path: Path) -> None:
    files = {"index.md": ROOT_INDEX + entry("a.md"), "a.md": "# A\n"}
    assert bundle(tmp_path, files) == ["docs/a.md: no frontmatter"]


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("---\na: [\n---\n", "invalid YAML"),
        ("---\na: 1\n", "unterminated frontmatter"),
    ],
)
def test_unreadable_frontmatter_is_one_error(
    tmp_path: Path, text: str, message: str
) -> None:
    files = {"index.md": ROOT_INDEX + entry("a.md"), "a.md": text}
    [error] = bundle(tmp_path, files)
    assert error.startswith(f"docs/a.md: {message}")


def test_an_unreadable_file_does_not_stop_the_walk(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX + entry("a.md") + entry("b.md"),
        "a.md": "---\na: 1\n",
        "b.md": "# B\n",
    }
    assert bundle(tmp_path, files) == [
        "docs/a.md: unterminated frontmatter",
        "docs/b.md: no frontmatter",
    ]


def test_unreadable_index_frontmatter_is_one_error(tmp_path: Path) -> None:
    [error] = bundle(tmp_path, {"index.md": FENCE + "okf_version: [\n" + FENCE})
    assert error.startswith("docs/index.md: invalid YAML: ")


def test_root_index_needs_frontmatter(tmp_path: Path) -> None:
    assert bundle(tmp_path, {"index.md": "# Docs\n"}) == [
        "docs/index.md: no frontmatter"
    ]


def test_root_index_takes_only_okf_version(tmp_path: Path) -> None:
    files = {"index.md": FENCE + "okf_version: 0.2\ntitle: x\n" + FENCE}
    assert bundle(tmp_path, files) == [
        (
            "docs/index.md: $: Additional properties are not allowed "
            "('title' was unexpected)"
        ),
        "docs/index.md: $.okf_version: '0.2' was expected",
    ]


def test_nested_index_has_no_frontmatter(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX + entry("sub/b.md"),
        "sub/b.md": DOC,
        "sub/index.md": FENCE + 'okf_version: "0.2"\n' + FENCE,
    }
    assert bundle(tmp_path, files) == [
        "docs/sub/index.md: index.md must have no frontmatter"
    ]


@pytest.mark.parametrize(
    "line",
    [
        "* [T](a.md)",
        "* [T](a.md) -",
        "* [T](a.md) - ",
        "* [T](a.md#top) - Desc.",
        "* [](a.md) - Desc.",
        "* [T]() - Desc.",
        "* [T](a b.md) - Desc.",
        "* plain text",
    ],
)
def test_malformed_index_entries(tmp_path: Path, line: str) -> None:
    files = {"index.md": ROOT_INDEX + entry("a.md") + line + "\n", "a.md": DOC}
    assert bundle(tmp_path, files) == [f"docs/index.md: malformed index entry: {line}"]


def test_dash_and_star_without_space_are_not_entries(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX + entry("a.md") + "- [x](y.md)\n*emphasis*\n",
        "a.md": DOC,
    }
    assert bundle(tmp_path, files) == []


def test_entry_listing_a_missing_file_lists_nothing(tmp_path: Path) -> None:
    files = {"index.md": ROOT_INDEX + entry("gone.md"), "a.md": DOC}
    assert bundle(tmp_path, files) == ["docs/a.md: not listed in any index.md"]


def test_index_is_not_itself_listed(tmp_path: Path) -> None:
    assert bundle(tmp_path, {"index.md": ROOT_INDEX}) == []


@pytest.mark.parametrize(
    "name", ["bad name.md", "-lead.md", ".hidden.md", "a/b c/x.md"]
)
def test_invalid_concept_id_segment(tmp_path: Path, name: str) -> None:
    bad = name.removesuffix(".md").split("/")
    segment = next(part for part in bad if part.startswith(("-", ".")) or " " in part)
    files = {"index.md": ROOT_INDEX + entry(name.replace(" ", "%20")), name: DOC}
    errors = bundle(tmp_path, files)
    assert f"docs/{name}: invalid concept id segment {segment!r}" in errors


def test_valid_concept_id_segments(tmp_path: Path) -> None:
    name = "A_b-1.2/Z9.md"
    assert bundle(tmp_path, {"index.md": ROOT_INDEX + entry(name), name: DOC}) == []


# repository


def test_repo_markdown_selection(tmp_path: Path) -> None:
    make_repo(
        tmp_path,
        {
            "README.md": DOC,
            "docs/a.md": "x",
            "pkg/b.md": "x",
            "pkg/.hid/c.md": "x",
            ".github/d.md": "x",
            "pkg/testdata/f.md": "x",
            "testdata/g.md": "x",
            "pkg/testdata-old/h.md": "x",
            "pkg/my-testdata/i.md": "x",
            "e.txt": "x",
            "z.md/inside.txt": "x",
            "zz.md": "x",
        },
    )
    assert check_docs.repo_markdown(tmp_path) == [
        tmp_path / "README.md",
        tmp_path / "pkg/b.md",
        tmp_path / "pkg/my-testdata/i.md",
        tmp_path / "pkg/testdata-old/h.md",
        tmp_path / "zz.md",
    ]


def test_repo_markdown_does_not_skip_names_that_only_start_like_docs(
    tmp_path: Path,
) -> None:
    make_repo(tmp_path, {"docs-old/a.md": "x", "other-docs/b.md": "x"})
    assert check_docs.repo_markdown(tmp_path) == [
        tmp_path / "docs-old/a.md",
        tmp_path / "other-docs/b.md",
    ]


def test_repo_markdown_skips_another_bundle(tmp_path: Path) -> None:
    make_repo(tmp_path, {"docs/a.md": "x", "book/b.md": "x"})
    assert check_docs.repo_markdown(tmp_path, "book") == [tmp_path / "docs/a.md"]


def test_check_repo(tmp_path: Path) -> None:
    make_repo(
        tmp_path,
        {
            "README.md": DOC,
            "AGENTS.md": "# Agents\n",
            "pkg/plain.md": "# Plain\n",
            "pkg/notes.md": "---\ntype: Notes\n---\n",
            "pkg/broken.md": "---\na: [\n---\n",
            "pkg/good.md": DOC,
            "pkg/AGENTS.md": "# Agents\n",
            "pkg/CLAUDE.md": DOC,
            "docs/skipped.md": "no frontmatter",
        },
    )
    errors = check_docs.check_repo(tmp_path, doc_validator())
    assert errors[0] == "README.md: must have no frontmatter"
    assert errors[1] == "pkg/CLAUDE.md: must have no frontmatter"
    assert errors[2].startswith("pkg/broken.md: invalid YAML: ")
    assert errors[-1] == "pkg/plain.md: no frontmatter"
    assert len(errors) == 9
    assert all(line.startswith("pkg/notes.md: $") for line in errors[3:-1])


def test_bundle_agent_files_are_not_documents(tmp_path: Path) -> None:
    files = {
        "index.md": ROOT_INDEX,
        "AGENTS.md": "# Agents\n",
        "CLAUDE.md": "@AGENTS.md\n",
        "sub/AGENTS.md": DOC,
    }
    assert bundle(tmp_path, files) == ["docs/sub/AGENTS.md: must have no frontmatter"]


# main


def project(root: Path, files: dict[str, str]) -> Path:
    shutil.copytree(SCHEMAS, root / "docs" / "schemas")
    return make_repo(root, files)


def test_main_reports_ok(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    root = project(
        tmp_path,
        {
            "README.md": "# R\n",
            "pkg/notes.md": DOC,
            "docs/index.md": ROOT_INDEX + entry("a.md"),
            "docs/a.md": DOC,
        },
    )
    assert check_docs.main([str(root)]) == 0
    assert (
        capsys.readouterr().out
        == "OK: docs bundle and repository frontmatter conform\n"
    )


def test_main_prints_every_error_and_fails(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    root = project(
        tmp_path, {"README.md": DOC, "docs/index.md": ROOT_INDEX, "docs/a.md": DOC}
    )
    assert check_docs.main([str(root)]) == 1
    assert capsys.readouterr().out == (
        "docs/a.md: not listed in any index.md\nREADME.md: must have no frontmatter\n"
    )


def test_main_reports_an_invalid_schema(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    root = project(tmp_path, {})
    (root / "docs" / "schemas" / "frontmatter.schema.json").write_text('{"type": 5}')
    assert check_docs.main([str(root)]) == 1
    assert capsys.readouterr().out.startswith(
        "invalid schema: 5 is not valid under any"
    )


def test_main_reports_an_invalid_index_schema(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    root = project(tmp_path, {})
    (root / "docs" / "schemas" / "index-frontmatter.schema.json").write_text(
        '{"type": 5}'
    )
    assert check_docs.main([str(root)]) == 1
    assert capsys.readouterr().out.startswith(
        "invalid schema: 5 is not valid under any"
    )


def test_main_defaults_to_the_current_directory_and_argv(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    project(tmp_path, {"docs/index.md": ROOT_INDEX})
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["check_docs.py"])
    assert check_docs.main() == 0
    assert capsys.readouterr().out.startswith("OK: ")


def test_main_help_describes_the_tool(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as caught:
        check_docs.main(["--help"])
    assert caught.value.code == 0
    out = " ".join(capsys.readouterr().out.split())
    assert " Check docs and Markdown frontmatter. " in out
    assert f"--bundle BUNDLE {check_docs.BUNDLE_HELP}" in out
    assert f"--schemas SCHEMAS {check_docs.SCHEMAS_HELP}" in out


def test_main_takes_another_bundle_and_schemas(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(
        tmp_path,
        {
            "README.md": "# R\n",
            "book/index.md": ROOT_INDEX + entry("a.md"),
            "book/a.md": DOC,
            "book/b.md": DOC,
            "docs/c.md": "no frontmatter",
        },
    )
    shutil.copytree(SCHEMAS, tmp_path / "meta")
    args = ["--bundle", "book", "--schemas", "meta", str(tmp_path)]
    assert check_docs.main(args) == 1
    assert capsys.readouterr().out == (
        "book/b.md: not listed in any index.md\ndocs/c.md: no frontmatter\n"
    )
    shutil.copytree(SCHEMAS, tmp_path / "book" / "schemas")
    assert check_docs.main(["--bundle", "book", str(tmp_path)]) == 1


def test_a_missing_bundle_index_names_the_bundle(tmp_path: Path) -> None:
    errors = check_docs.check_bundle(
        tmp_path, doc_validator(), index_validator(), "book"
    )
    assert errors == ["book/index.md: missing bundle-root index"]
