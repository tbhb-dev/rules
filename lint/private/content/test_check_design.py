# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore checkerbot checkerbotany anycheckerbot ncheckerbot

import json
import re
import shutil
from pathlib import Path

import jsonschema
import pytest

from lint.private.content import check_design as checker

FIXTURES = Path(__file__).resolve().parents[2] / "tests/content/testdata"
GOOD = FIXTURES / "good/designs/small-design"


@pytest.fixture
def design(tmp_path: Path) -> Path:
    directory = tmp_path / "designs/small-design"
    shutil.copytree(GOOD, directory)
    return directory


def replace(directory: Path, before: str, after: str, name: str = "README.md") -> None:
    path = directory / name
    path.write_text(path.read_text().replace(before, after))


def test_good(design: Path) -> None:
    assert checker.check(design, []) == []


@pytest.mark.parametrize(
    ("case", "reason"),
    json.loads((FIXTURES / "failures.json").read_text()).items(),
)
def test_bad_fixtures(case: str, reason: str) -> None:
    errors = checker.check(FIXTURES / case, ["checkerbot"])
    assert any(reason in error for error in errors)
    assert all(re.match(r".+:\d+: .+", error) for error in errors)


@pytest.mark.parametrize(
    "case", ["stale", "bad_slug", "nested", "no_readme", "missing_metadata"]
)
def test_bad_index_fixtures(case: str) -> None:
    assert checker.index(
        FIXTURES / ("index_" + case), "designs/README.md", [], 250, write=False
    )


@pytest.mark.parametrize(
    "contents",
    ["---\nnull\n---\n", "---\n[]\n---\n", "---\nx: [\n---\n", "no frontmatter"],
)
def test_read_errors(tmp_path: Path, contents: str) -> None:
    path = tmp_path / "document.md"
    path.write_text(contents)
    assert checker.read(path)[2]


def test_unreadable(tmp_path: Path) -> None:
    assert "cannot read file" in checker.read(tmp_path / "missing.md")[2][0]
    path = tmp_path / "invalid.md"
    path.write_bytes(b"\xff")
    assert "cannot read file" in checker.read(path)[2][0]


@pytest.mark.parametrize(
    ("key", "value", "message"),
    [
        ("title", "", "title must be"),
        ("description", 3, "description must be"),
        ("tags", "design", "tags must be"),
        ("tags", [3], "tags must be"),
        ("tags", ["Not_kebab"], "tags must be"),
        ("updated", "20260230", "updated must be a"),
        ("updated", "20261111", "updated must use"),
        ("decisions_open", -1, "nonnegative integer"),
        ("decisions_open", True, "nonnegative integer"),
    ],
)
def test_metadata(design: Path, key: str, value: object, message: str) -> None:
    _, data, _ = checker.read(design / "README.md")
    data[key] = value
    assert any(
        message in error for error in checker.metadata(design / "README.md", data)
    )


@pytest.mark.parametrize("status", ["draft", "decided", "superseded"])
def test_statuses(design: Path, status: str) -> None:
    replace(design, "status: draft", "status: " + status)
    assert checker.check(design, []) == []


def test_zero_decisions_and_no_appendices(design: Path) -> None:
    path = design / "README.md"
    text = path.read_text()
    text = re.sub(
        r"### D1\..*?(?=## Already decided)", "None.\n\n", text, flags=re.DOTALL
    )
    path.write_text(
        text.split("## Appendices")[0].replace("decisions_open: 1", "decisions_open: 0")
    )
    for appendix in design.glob("[AB]-*.md"):
        appendix.unlink()
    assert checker.check(design, []) == []
    replace(design, "## Decisions for tbhb", "## Other")
    assert any("section order" in error for error in checker.check(design, []))


def test_two_decisions(design: Path) -> None:
    text = (design / "README.md").read_text()
    item = text[text.index("### D1.") : text.index("## Already decided")]
    replace(
        design, "## Already decided", item.replace("D1.", "D2.") + "## Already decided"
    )
    replace(design, "decisions_open: 1", "decisions_open: 2")
    assert checker.check(design, []) == []
    replace(design, "- **If no:** Keep the current process.", "- **If no:**")
    assert (
        sum("missing If no bullet" in error for error in checker.check(design, [])) == 2
    )


@pytest.mark.parametrize("limit", [0, 1000])
def test_line_limit(design: Path, limit: int) -> None:
    replace(design, "Ship a check.", "Ship a check.\n" * 260)
    assert checker.check(design, [], limit) == []


def test_summary_boundary(design: Path) -> None:
    replace(design, "Make designs easy to review with a reusable check.", "word " * 150)
    assert checker.check(design, []) == []
    replace(design, "word " * 150, "word " * 151)
    assert any("Summary exceeds" in error for error in checker.check(design, []))


def test_status_position(design: Path) -> None:
    path = design / "README.md"
    text = path.read_text()
    table = text[text.index("| Status") : text.index("## Summary")]
    text = text.replace(table, "").replace("## Summary\n", "## Summary\n\n" + table)
    assert any(
        "status table" in error
        for error in checker.sections(path, text, appendices=True, max_lines=250)
    )
    assert checker.sections(path, table, appendices=False, max_lines=250)
    assert checker.sections(path, "", appendices=False, max_lines=250)


@pytest.mark.parametrize(
    "label", ["proven: spike", "Existing: source", "new", "UNVERIFIED"]
)
def test_evidence_labels(design: Path, label: str) -> None:
    replace(design, "existing: primary documentation", label)
    assert checker.check(design, []) == []


def test_risk_short_row() -> None:
    assert checker.check_risks(Path("README.md"), 4, ["| Risk | Evidence |", "| one |"])
    assert checker.check_risks(Path("README.md"), 4, ["| no header |"])
    assert checker.check_risks(Path("README.md"), 4, ["paragraph"])
    assert (
        checker.check_risks(
            Path("README.md"),
            4,
            ["| Evidence | Risk |", "| new: source | escaped \\| pipe |"],
        )
        == []
    )


def test_prose() -> None:
    text = (
        "word `code` ``a ` span``\n<!-- comment\nhidden -->\n"
        "````md\n### D1. Fake\n```\n~~~~\n````\nend"
    )
    result = checker.prose(text)
    assert len(result) == len(text)
    assert result.count("\n") == text.count("\n")
    assert "code" not in result
    assert "Fake" not in result
    assert "hidden" not in result
    assert result.endswith("end")
    assert checker.prose("~~~\nword\n~~~\nend").endswith("end")
    assert "word" not in checker.prose("```\nword")


def test_forbidden_terms(design: Path) -> None:
    replace(
        design,
        "Ship a check.",
        "`checkerbot` ``checkerbot `code` `` checkerbotany anycheckerbot\n\n"
        "```\ncheckerbot\n```",
    )
    assert checker.check(design, ["checkerbot"]) == []
    replace(design, "## Proposal", "## Proposal\n\nCHECKERBOT and checkerbot-other.")
    assert (
        sum(
            "forbidden term" in error for error in checker.check(design, ["checkerbot"])
        )
        == 2
    )
    replace(design, "# Evidence", "# Evidence\n\nuser.name+", "A-evidence.md")
    assert any(
        "forbidden term: user.name+" in error
        for error in checker.check(design, ["user.name+"])
    )


def test_links(design: Path) -> None:
    path = design / "README.md"
    (design / "a file.txt").write_text("asset")
    text = (
        "[web](https://example.com) [mail](mailto:user@example.com) "
        "[net](//example.com) [self](#summary) [file](<a%20file.txt>)\n"
        "[ref]: B-alternatives.md\n![image](missing.png)"
    )
    targets, errors = checker.links(path, text)
    assert path.resolve() in targets
    assert (design / "a file.txt").resolve() in targets
    assert (design / "B-alternatives.md").resolve() in targets
    assert errors == [
        checker.problem(path, 3, "relative link does not resolve: missing.png")
    ]


def test_empty(tmp_path: Path) -> None:
    assert "no design directories" in checker.check(tmp_path, [])[0]
    assert (
        "missing designs directory"
        in checker.render_index(tmp_path / "missing", [])[1][0]
    )
    assert checker.render_index(tmp_path, [])[1] == []
    (tmp_path / "stray.txt").write_text("stray")
    assert "expected a design directory" in checker.render_index(tmp_path, [])[1][0]


def test_cell() -> None:
    assert checker.cell("a\\b|[c]<d>\n\re") == "a\\\\b\\|\\[c\\]&lt;d&gt;  e"


def test_index_stability_and_sorting(design: Path) -> None:
    root = design.parents[1]
    shutil.copytree(design, design.parent / "a-design")
    assert checker.index(root, "designs/README.md", [], 250, write=False)
    assert checker.index(root, "designs/README.md", [], 250, write=True) == []
    first = (root / "designs/README.md").read_bytes()
    assert checker.index(root, "designs/README.md", [], 250, write=True) == []
    assert first == (root / "designs/README.md").read_bytes()
    assert first.index(b"a-design/README.md") < first.index(b"small-design/README.md")
    assert checker.index(root, "designs/README.md", [], 250, write=False) == []
    (root / "designs/README.md").write_bytes(first + b"\n")
    assert (
        "stale designs index"
        in checker.index(root, "designs/README.md", [], 250, write=False)[0]
    )


@pytest.mark.parametrize("out", ["/outside/README.md", "../README.md"])
def test_index_path(tmp_path: Path, out: str) -> None:
    assert "workspace-relative" in checker.index(tmp_path, out, [], 250, write=True)[0]


def test_generator_and_main(
    design: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    root = design.parents[1]
    manifest = tmp_path / "sources.txt"
    manifest.write_text(
        "".join(
            path.relative_to(root).as_posix() + "\n"
            for path in sorted(design.iterdir())
        )
    )
    args = [str(root), "--manifest", str(manifest), "--index", "designs/README.md"]
    assert checker.main(args) == 0
    assert capsys.readouterr().out == "OK: designs conform and index is current\n"
    first = (root / "designs/README.md").read_bytes()
    assert checker.main(args) == 0
    assert (root / "designs/README.md").read_bytes() == first
    assert checker.main([str(root), "--index", "designs/README.md"]) == 0
    assert "index is current" in capsys.readouterr().out
    assert checker.main([str(design)]) == 0
    replace(design, "status: draft", "status: bad")
    assert checker.main(args) == 1
    assert (root / "designs/README.md").read_bytes() == first
    assert "status must be" in capsys.readouterr().out
    assert checker.main([str(design), "--forbidden-term", "check"]) == 1


def test_main_default(design: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(design)
    assert checker.main([]) == 0


def test_index_frontmatter(design: Path) -> None:
    root = design.parents[1]
    assert checker.index(root, "designs/README.md", [], 250, write=True) == []
    _, data, errors = checker.read(root / "designs/README.md")
    assert not errors
    schema = (
        Path(__file__).resolve().parents[3] / "docs/schemas/frontmatter.schema.json"
    )
    jsonschema.validate(data, json.loads(schema.read_text()))


def test_manifest_requires_index(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit, match="2"):
        checker.main(["--manifest", str(tmp_path / "sources.txt")])
    assert capsys.readouterr().err.endswith("error: --manifest requires --index\n")


def test_reference_data(design: Path) -> None:
    records = design.parents[1] / "records"
    records.mkdir()
    (records / "decision.md").write_text(
        "---\ntype: Decision Record\n---\n# Decision\n"
    )
    replace(design, "Use Markdown.", "Use [Markdown](../../records/decision.md).")
    assert checker.check(design.parents[1], []) == []


def test_terms_in_comments(design: Path) -> None:
    replace(design, "Ship a check.", "Ship a check. <!-- checkerbot -->")
    assert any(
        "forbidden term" in error for error in checker.check(design, ["checkerbot"])
    )


def test_summary_counts_inline_code(design: Path) -> None:
    replace(
        design,
        "Make designs easy to review with a reusable check.",
        "word " * 150 + "`extra word`",
    )
    assert any("Summary exceeds" in error for error in checker.check(design, []))


def test_anchors(design: Path) -> None:
    path = design / "README.md"
    assert checker.links(path, "[good](#summary)")[1] == []
    assert "anchor does not resolve" in checker.links(path, "[bad](#missing)")[1][0]
    assert checker.anchors(
        '# A `code` heading!\n# A code heading!\n<a id="custom"></a>'
    ) == {"a-code-heading", "a-code-heading-1", "custom"}
    target = design / "broken.md"
    target.write_bytes(b"\xff")
    assert (
        "cannot read relative link"
        in checker.links(path, "[bad](broken.md#anchor)")[1][0]
    )


def test_invalid_url(design: Path) -> None:
    assert (
        "invalid link destination"
        in checker.links(design / "README.md", "[bad](http://[)")[1][0]
    )


@pytest.mark.parametrize("key", checker.REQUIRED)
def test_required_keys(design: Path, key: str) -> None:
    _, data, _ = checker.read(design / "README.md")
    data.pop(key)
    assert any(
        "missing required frontmatter: " + key in error
        for error in checker.metadata(design / "README.md", data)
    )


def test_plain_decision_labels(design: Path) -> None:
    path = design / "README.md"
    path.write_text(path.read_text().replace("**", ""))
    assert checker.check(design, []) == []


@pytest.mark.parametrize(
    ("case", "expected"),
    json.loads((FIXTURES / "diagnostics.json").read_text()).items(),
)
def test_diagnostic_contract(case: str, expected: list[str]) -> None:
    root = FIXTURES / case
    if case.startswith("index_"):
        errors = checker.index(root, "designs/README.md", [], 250, write=False)
    else:
        errors = checker.check(root, ["checkerbot"])
    assert [error.removeprefix(root.as_posix() + "/") for error in errors] == expected


def test_render_contract(monkeypatch: pytest.MonkeyPatch) -> None:
    read_text = Path.read_text

    def read_exact_case(path: Path, *, encoding: str | None = None) -> str:
        # Emulate case-sensitive reads on every filesystem.
        if path.name not in {entry.name for entry in path.parent.iterdir()}:
            raise FileNotFoundError(path)
        return read_text(path, encoding=encoding)

    monkeypatch.setattr(Path, "read_text", read_exact_case)
    for name in ("readme.md", "README.MD"):
        with pytest.raises(FileNotFoundError):
            (GOOD / name).read_text()
    rendered, errors = checker.render_index(FIXTURES / "good/designs", [])
    assert not errors
    assert rendered == (FIXTURES / "good/designs/README.md").read_text()


def test_read_contract(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = tmp_path / "document.md"
    text = "---\nfield: value\n---\n\n# Document\n"
    path.write_text(text)
    assert checker.read(path) == (text, {"field": "value"}, [])
    path.write_text("---\n[]\n---\n")
    assert checker.read(path) == (
        "---\n[]\n---\n",
        {},
        [f"{path.as_posix()}:2: frontmatter must be a mapping"],
    )

    def failed_read(_self: Path, *, encoding: str) -> str:
        assert encoding.lower() == "utf-8"
        msg = "unreadable"
        raise OSError(msg)

    monkeypatch.setattr(Path, "read_text", failed_read)
    assert checker.read(path) == (
        "",
        {},
        [f"{path.as_posix()}:1: cannot read file: unreadable"],
    )


def test_line_boundary_and_cli(
    design: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = design / "README.md"
    text = path.read_text()
    path.write_text(text + "\n" * (250 - len(text.splitlines())))
    assert checker.check(design, []) == []
    assert checker.main([str(design)]) == 0
    assert capsys.readouterr().out == "OK: designs conform\n"
    path.write_text(path.read_text() + "\n")
    assert checker.check(design, []) == [
        f"{path.as_posix()}:251: README exceeds 250 lines"
    ]
    assert checker.main([str(design)]) == 1
    assert (
        capsys.readouterr().out == f"{path.as_posix()}:251: README exceeds 250 lines\n"
    )
    assert checker.main([str(design), "--max-lines", "0"]) == 0
    assert capsys.readouterr().out == "OK: designs conform\n"


def test_help(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr("sys.argv", ["check_design.py"])
    monkeypatch.setenv("COLUMNS", "80")
    with pytest.raises(SystemExit, match="0"):
        checker.main(["--help"])
    assert capsys.readouterr().out == (FIXTURES / "help.txt").read_text()


def test_compact_sections(design: Path) -> None:
    path = design / "README.md"
    replace(
        design,
        "Make designs easy to review with a reusable check.",
        "word " * 150 + "\nextra",
    )
    replace(design, "\n\n##", "\n##")
    assert checker.sections(path, path.read_text(), appendices=True, max_lines=250) == [
        f"{path.as_posix()}:17: Summary exceeds 150 words"
    ]


def test_decisions_do_not_borrow_bullets() -> None:
    lines = ["### D1. First?"] + [f"- **{label}:** answer" for label in checker.BULLETS]
    lines += ["### D2. Second?"] + [
        f"- **{label}:** answer" for label in checker.BULLETS
    ]
    lines.pop(1)
    assert checker.check_decisions(Path("README.md"), 1, lines) == [
        "README.md:2: D item missing Recommendation bullet"
    ]
    lines.insert(1, "- **Recommendation:** answer")
    lines.pop()
    assert checker.check_decisions(Path("README.md"), 1, lines) == [
        "README.md:8: D item missing Reversible bullet"
    ]


def test_prose_preserves_only_prose() -> None:
    assert checker.prose("```md\ncode\n```\ntext") == "     \n    \n   \ntext"
    assert checker.prose("`code`", keep_spans=True) == "`code`"
    assert checker.prose("<!-- comment -->", keep_comments=True) == "<!-- comment -->"


def test_html_and_bare_markdown_anchors(design: Path) -> None:
    path = design / "README.md"
    (design / "X-file.txt").write_text("asset")
    assert checker.links(path, "[file](X-file.txt)")[1] == []
    assert checker.anchors("# A <em>code</em> heading") == {"a-code-heading"}
    (design / "plain.md").write_text("# Plain\n")
    assert checker.links(path, "[plain](plain.md#plain)")[1] == []


def test_missing_readme_discovery(design: Path, tmp_path: Path) -> None:
    (design / "README.md").rename(design / "draft.md")
    for appendix in design.glob("[AB]-*.md"):
        appendix.unlink()
    assert (
        checker.check(design, [])[0]
        == f"{design.as_posix()}/README.md:1: missing README.md"
    )
    bare = tmp_path / "bare"
    bare.mkdir()
    (bare / "README.md").write_text("# Bare\n")
    assert f"{bare.as_posix()}/README.md:1: missing frontmatter" in checker.check(
        bare, []
    )


def test_zero_count_without_decisions_section(design: Path) -> None:
    replace(design, "decisions_open: 1", "decisions_open: 0")
    replace(design, "## Decisions for tbhb", "## Other")
    assert not any("decisions_open" in error for error in checker.check(design, []))


def test_empty_and_stray_diagnostics(design: Path, tmp_path: Path) -> None:
    folder = tmp_path / "missing"
    assert checker.render_index(folder, []) == (
        "",
        [f"{folder.as_posix()}:1: missing designs directory"],
    )
    assert checker.check(folder, []) == [
        f"{folder.as_posix()}:1: no design directories found"
    ]
    stray = design.parent / "a-stray.txt"
    stray.write_text("stray")
    rendered, errors = checker.render_index(design.parent, [])
    assert errors == [f"{stray.as_posix()}:1: expected a design directory"]
    assert "[Small design](small-design/README.md)" in rendered


def test_index_path_diagnostic(tmp_path: Path) -> None:
    assert checker.index(tmp_path, "../README.md", [], 250, write=True) == [
        "../README.md:1: index output must be a workspace-relative path"
    ]


def test_index_and_generator_limits(
    design: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = design.parents[1]
    path = design / "README.md"
    text = path.read_text()
    path.write_text(text + "\n" * (251 - len(text.splitlines())))
    expected = [f"{path.as_posix()}:251: README exceeds 250 lines"]
    assert checker.check_directory(design, []) == expected
    assert checker.render_index(design.parent, [])[1] == expected
    assert checker.index(root, "designs/README.md", [], 250, write=True) == expected
    assert checker.index(root, "designs/README.md", [], 0, write=True) == []
    assert checker.main([str(root), "--index", "designs/README.md"]) == 1
    assert (
        checker.main([str(root), "--index", "designs/README.md", "--max-lines", "0"])
        == 0
    )
    manifest = tmp_path / "sources.txt"
    manifest.write_text(
        "".join(file.relative_to(root).as_posix() + "\n" for file in design.iterdir())
    )
    original_read = Path.read_text

    def read_manifest(
        self: Path,
        encoding: str | None = None,
        errors: str | None = None,
        newline: str | None = None,
    ) -> str:
        if self == manifest:
            assert encoding == "utf-8"
        return original_read(self, encoding=encoding, errors=errors, newline=newline)

    monkeypatch.setattr(Path, "read_text", read_manifest)
    assert checker.generate(root, manifest, "designs/README.md", [], 250)
    assert checker.generate(root, manifest, "designs/README.md", [], 0) == []
    assert (
        checker.main(
            [str(root), "--index", "designs/README.md", "--manifest", str(manifest)]
        )
        == 1
    )
    assert (
        checker.main(
            [
                str(root),
                "--index",
                "designs/README.md",
                "--manifest",
                str(manifest),
                "--max-lines",
                "0",
            ]
        )
        == 0
    )


def test_cli_forbidden_terms(design: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert (
        checker.main(
            [
                str(design),
                "--forbidden-term",
                "maintainer",
                "--forbidden-term",
                "Markdown",
            ]
        )
        == 1
    )
    assert "forbidden term: maintainer" in capsys.readouterr().out


def test_cli_stale_index(design: Path, capsys: pytest.CaptureFixture[str]) -> None:
    root = design.parents[1]
    output = design.parent / "README.md"
    output.write_text("# Stale\n")
    assert checker.main([str(root), "--index", "designs/README.md"]) == 1
    assert output.read_text() == "# Stale\n"
    assert (
        capsys.readouterr().out
        == f"{output.as_posix()}:1: stale designs index; run the designs_index target\n"
    )


def test_three_decisions() -> None:
    lines = []
    for number, missing in enumerate(checker.BULLETS[:3], 1):
        lines.append(f"### D{number}. Question?")
        lines.extend(
            f"- {label}: answer" for label in checker.BULLETS if label != missing
        )
    assert checker.check_decisions(Path("README.md"), 1, lines) == [
        "README.md:2: D item missing Recommendation bullet",
        "README.md:7: D item missing Why bullet",
        "README.md:12: D item missing If yes bullet",
    ]


def test_risk_missing_cell() -> None:
    assert checker.check_risks(
        Path("README.md"), 4, ["| Risk | Evidence |", "| one"]
    ) == ["README.md:6: Evidence must start with proven, existing, new or unverified"]


def test_invalid_design_does_not_stop_index(design: Path) -> None:
    bad = design.parent / "a-bad"
    shutil.copytree(design, bad)
    replace(bad, "status: draft", "status: bad")
    rendered, errors = checker.render_index(design.parent, [])
    assert errors == [
        f"{bad.as_posix()}/README.md:1: status must be draft, decided or superseded"
    ]
    assert "[Small design](small-design/README.md)" in rendered
    assert "a-bad/README.md" not in rendered


def test_summary_counts_fenced_code(design: Path) -> None:
    replace(
        design,
        "Make designs easy to review with a reusable check.",
        "```text\n" + "word " * 151 + "\n```",
    )
    assert any("Summary exceeds" in error for error in checker.check(design, []))


def test_decision_code_values(design: Path) -> None:
    replace(design, "- **Recommendation:** Accept it.", "- **Recommendation:** `true`")
    assert checker.check(design, []) == []
