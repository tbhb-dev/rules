# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for the Markdown link check."""

from pathlib import Path
lazy import subprocess

import pytest

from repo.tests import check_markdown_links as checker

DATA = Path(__file__).parent / "testdata" / "markdown_links"


def tree(root: Path, files: dict[str, str]) -> Path:
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


def test_strip_code_keeps_line_numbers() -> None:
    text = "---\nk: [a](b)\n---\ntext `[x](y)`\n```\n[z](w)\n```\n~~~~\n```\n~~~~\nend"
    out = checker.strip_code(text)
    assert out.count("\n") == text.count("\n")
    assert "[" not in out
    assert out.endswith("end")
    assert out.split("\n")[3].startswith("text ")


def test_strip_code_fence_needs_matching_close() -> None:
    out = checker.strip_code("```\n~~~\n[a](b)\n```\n[c](d)\n````\n```\n[e](f)\n````\n")
    assert "[a](b)" not in out
    assert "[c](d)" in out
    assert "[e](f)" not in out


def test_strip_code_unclosed_frontmatter_is_text() -> None:
    assert "[a](b)" in checker.strip_code("---\n[a](b)\n")


def test_strip_code_spans() -> None:
    out = checker.strip_code("`[a](b)` ``[c`](d)`` [e](f) `\n[g](h)` ")
    assert "[a](b)" not in out
    assert "[c`](d)" not in out
    assert "[e](f)" in out
    assert "[g](h)" not in out


def test_destinations() -> None:
    text = (
        '[a](x.md) ![i](img.png "t") [b](<s p.md>) [c](f(1).md)\n'
        '[d]( y.md )\n[r]: z.md\n   [q]: <w.md> "t"\n[e]()\n'
    )
    assert checker.destinations(text) == [
        (1, "x.md"),
        (1, "img.png"),
        (1, "s p.md"),
        (1, "f(1).md"),
        (2, "y.md"),
        (3, "z.md"),
        (4, "w.md"),
        (5, ""),
    ]


def test_anchors_follow_github() -> None:
    text = (
        "---\n# not: a heading\n---\n# Hello, `World`!\n\n## Q&A [link](u) *x*\n"
        "Setext\n===\n\nSub\n---\n## Hello, World!\n## Hello, World!\n"
        "# Closed ##\n#\n####### seven\n```\n# code\n```\n    \n---\n"
        "Para\ntext\n---\n"
    )
    assert checker.anchors(text) == {
        "hello-world",
        "hello-world-1",
        "hello-world-2",
        "qa-link-x",
        "setext",
        "sub",
        "closed",
        "",
        "text",
    }


def test_anchors_keep_underscore_and_hyphen() -> None:
    assert checker.anchors("# a_b-c d\n") == {"a_b-c-d"}


def test_anchors_atx_is_not_setext() -> None:
    assert checker.anchors("# A\n---\n") == {"a"}


def problem(
    dest: str, source: str = "d/a.md", page: set[str] | None = None
) -> str | None:
    tracked = {"d", "d/a.md", "d/b.md", "x.md", "d/s p.md"}
    return checker.link_problem(source, dest, tracked, page or {"top"})


def test_link_problem_resolves() -> None:
    assert problem("b.md") is None
    assert problem("../x.md") is None
    assert problem("/x.md") is None
    assert problem("../d/") is None
    assert problem("s%20p.md") is None
    assert problem("./b.md") is None
    assert problem("#top") is None
    assert problem("#TOP") is None
    assert problem("#") is None
    assert problem("") is None
    assert problem("x.md", source="top.md") is None


@pytest.mark.parametrize(
    "dest", ["https://a.example/x", "http://a", "mailto:a@b", "//a.example/x", "tel:1"]
)
def test_link_problem_skips_external(dest: str) -> None:
    assert problem(dest) is None


def test_link_problem_failures() -> None:
    assert problem("#nope") == "#nope matches no heading in this file"
    assert problem("c.md") == "c.md is not a tracked file or directory"
    assert problem("b.md#h") == (
        "b.md#h has a fragment on a link to another file: link to the file"
    )
    assert problem("../../x.md") == "../../x.md points outside the repository"
    assert problem("..", source="top.md") == ".. points outside the repository"
    assert problem("/c.md") == "/c.md is not a tracked file or directory"
    assert problem("c.md", source="top.md") == "c.md is not a tracked file or directory"


def test_parents() -> None:
    assert checker.parents({"a/b/c.md", "d.md"}) == {".", "a", "a/b"}


def test_exclusions_none_without_config(tmp_path: Path) -> None:
    assert checker.load_exclusions(tmp_path) == []


def test_exclusions_lines(tmp_path: Path) -> None:
    (tmp_path / ".markdown-links.toml").write_text(
        "# c\n[[exclude]]\nglob = 'a/*'\nreason = 'r'\n\n [[exclude]] \n"
        "glob = 'b'\nreason = 'r'\n"
    )
    assert checker.load_exclusions(tmp_path) == [("a/*", 2), ("b", 6)]


@pytest.mark.parametrize(
    ("body", "message"),
    [
        ("[[exclude]\n", ".markdown-links.toml: "),
        ("[[exclude]]\nglob = 'a'\n", ".markdown-links.toml:1: an exclusion has only"),
        (
            "[[exclude]]\nglob = 'a'\nreason = 'r'\nregex = 'x'\n",
            ".markdown-links.toml:1: an exclusion has only",
        ),
        (
            "[[exclude]]\nglob = ' '\nreason = 'r'\n",
            ".markdown-links.toml:1: glob must",
        ),
        ("[[exclude]]\nglob = 1\nreason = 'r'\n", ".markdown-links.toml:1: glob must"),
        (
            "[[exclude]]\nglob = 'a'\nreason = ' '\n",
            ".markdown-links.toml:1: a needs a nonblank reason",
        ),
        (
            "[[exclude]]\nglob = 'a'\nreason = 2\n",
            ".markdown-links.toml:1: a needs a nonblank reason",
        ),
    ],
)
def test_exclusions_invalid(tmp_path: Path, body: str, message: str) -> None:
    (tmp_path / ".markdown-links.toml").write_text(body)
    with pytest.raises(checker.CheckError) as info:
        checker.load_exclusions(tmp_path)
    assert str(info.value).startswith(message)


def test_tracked_files_walk(tmp_path: Path) -> None:
    tree(tmp_path, {"a.md": "", "d/b.md": ""})
    assert checker.tracked_files(tmp_path, None) == {"a.md", "d/b.md"}


def test_tracked_files_git(tmp_path: Path) -> None:
    tree(tmp_path, {"a.md": "", "d/b.md": "", "ignored.md": ""})
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "a.md", "d/b.md"], cwd=tmp_path, check=True)
    assert checker.tracked_files(tmp_path, "git") == {"a.md", "d/b.md"}


def test_tracked_files_git_failures(tmp_path: Path) -> None:
    with pytest.raises(checker.CheckError, match="git ls-files failed"):
        checker.tracked_files(tmp_path, str(tmp_path / "missing"))
    with pytest.raises(checker.CheckError, match="git ls-files failed"):
        checker.tracked_files(tmp_path, "false")


def test_check_clean_fixture() -> None:
    assert checker.check(DATA / "clean") == []


def test_check_reports_each_problem_with_line(tmp_path: Path) -> None:
    root = tree(
        tmp_path,
        {
            "b.md": "# B\n\n\n[x](gone.md) [y](#nope)\n",
            "a.md": "[z](d/)\n[w](b.md#h)\n",
            "d/n.txt": "[v](gone.md)\n",
        },
    )
    assert checker.check(root) == [
        "a.md:2: b.md#h has a fragment on a link to another file: link to the file",
        "b.md:4: gone.md is not a tracked file or directory",
        "b.md:4: #nope matches no heading in this file",
    ]


def test_check_exclusion_uses_source_path_glob(tmp_path: Path) -> None:
    root = tree(
        tmp_path,
        {
            "d/a.md": "[x](gone.md)\n[y](gone2.md)\n",
            "e/b.md": "[x](gone.md)\n",
            ".markdown-links.toml": (
                "[[exclude]]\nglob = 'd/**'\nreason = 'r'\n\n"
                "[[exclude]]\nglob = 'f/*'\nreason = 'r'\n"
            ),
        },
    )
    assert checker.check(root) == [
        "e/b.md:1: gone.md is not a tracked file or directory",
        ".markdown-links.toml:5: exclusion f/* matches no failing link",
    ]


def test_check_exclusion_for_clean_file_is_stale(tmp_path: Path) -> None:
    root = tree(
        tmp_path,
        {
            "a.md": "# A\n",
            ".markdown-links.toml": "[[exclude]]\nglob = 'a.md'\nreason = 'r'\n",
        },
    )
    assert checker.check(root) == [
        ".markdown-links.toml:1: exclusion a.md matches no failing link"
    ]


def test_check_ignores_non_markdown_and_untracked(tmp_path: Path) -> None:
    root = tree(tmp_path, {"a.txt": "[x](gone.md)\n", "a.mdx": "[x](gone.md)\n"})
    assert checker.check(root) == []


@pytest.mark.parametrize(
    ("case", "line"),
    [
        ("missing_file", "README.md:3: guide.md is not a tracked file or directory"),
        ("missing_dir", "README.md:3: nowhere/ is not a tracked file or directory"),
        ("bad_anchor", "README.md:3: #no-such-heading matches no heading in this file"),
        (
            "fragment",
            (
                "README.md:3: guide.md#intro has a fragment on a link to another "
                "file: link to the file"
            ),
        ),
        (
            "stale",
            ".markdown-links.toml:1: exclusion README.md matches no failing link",
        ),
    ],
)
def test_check_bad_fixtures(case: str, line: str) -> None:
    assert checker.check(DATA / "bad" / case) == [line]


def test_main_exit_codes(capsys: pytest.CaptureFixture[str]) -> None:
    assert checker.main([str(DATA / "clean")]) == 0
    assert capsys.readouterr().out == ""
    assert checker.main([str(DATA / "bad" / "missing_file")]) == 1
    assert capsys.readouterr().out == (
        "README.md:3: guide.md is not a tracked file or directory\n"
    )


def test_main_exit_two(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    (tmp_path / ".markdown-links.toml").write_text("[[exclude]\n")
    assert checker.main([str(tmp_path)]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith("check_markdown_links: .markdown-links.toml: ")
    assert checker.main([str(tmp_path / "missing")]) == 2
    assert checker.main([str(tmp_path), "--git", "false"]) == 2


def test_main_root_file_stands_for_its_directory(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    root = tree(tmp_path / "root", {"a.md": "[x](gone.md)\n"})
    (tmp_path / "other").mkdir()
    link = tmp_path / "other" / "a.md"
    link.symlink_to(root / "a.md")
    assert checker.main([str(link)]) == 1
    assert capsys.readouterr().out == (
        "a.md:1: gone.md is not a tracked file or directory\n"
    )


def test_main_resolves_git_in_test_srcdir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tree(tmp_path / "root", {"a.md": "# A\n"})
    tool = tree(tmp_path / "srcdir", {"bin/git": "#!/bin/sh\nprintf 'a.md\\0'\n"})
    (tool / "bin" / "git").chmod(0o755)
    monkeypatch.setenv("TEST_SRCDIR", str(tool))
    assert checker.main([str(root), "--git", "bin/git"]) == 0
    monkeypatch.delenv("TEST_SRCDIR")
    assert checker.main([str(root), "--git", "bin/git"]) == 2
