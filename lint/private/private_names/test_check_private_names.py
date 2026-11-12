# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Grammar and command-line contracts, using disposable Git histories."""

import io
import os
import subprocess
import sys
from pathlib import Path

import pytest

from lint.private.private_names import check_private_names as checker

# The committed exclusion documents this reviewed suffix-rule placeholder.
PRIVATE = "example-private"
CONFIGURED = "internal-example"


def problem(token: str) -> str:
    return f"'{token}' names a private repository; describe it generically instead"


@pytest.mark.parametrize(
    ("text", "names", "tokens"),
    [
        ("public", set(), []),
        (PRIVATE, set(), [PRIVATE]),
        (PRIVATE.upper(), set(), [PRIVATE.upper()]),
        (PRIVATE + ".GiT", set(), [PRIVATE + ".GiT"]),
        ("part." + PRIVATE, set(), ["part." + PRIVATE]),
        (PRIVATE + ".part", set(), []),
        (PRIVATE + "_suffix", set(), []),
        (PRIVATE + "-suffix", set(), []),
        (PRIVATE + "9", set(), []),
        (PRIVATE + "a", set(), []),
        ("-" + PRIVATE, set(), []),
        ("-private", set(), []),
        (CONFIGURED, {CONFIGURED}, [CONFIGURED]),
        (CONFIGURED.upper() + ".git", {CONFIGURED}, [CONFIGURED.upper() + ".git"]),
        ("a." + CONFIGURED, {CONFIGURED}, []),
        (CONFIGURED + ".b", {CONFIGURED}, []),
        ("a_" + CONFIGURED, {CONFIGURED}, []),
        (CONFIGURED + "_a", {CONFIGURED}, []),
        ("a-" + CONFIGURED, {CONFIGURED}, []),
        (CONFIGURED + "-a", {CONFIGURED}, []),
        ("9" + CONFIGURED, {CONFIGURED}, []),
        (CONFIGURED + "9", {CONFIGURED}, []),
        ("a" + CONFIGURED, {CONFIGURED}, []),
        (CONFIGURED + "a", {CONFIGURED}, []),
        ("." + PRIVATE, set(), []),
        (".." + PRIVATE, set(), []),
        # Keep the exact regex's treatment of a final punctuation dot.
        (PRIVATE + ".", set(), [PRIVATE]),
        ("é" + PRIVATE + "é", set(), [PRIVATE]),
        ("/" + PRIVATE + "/", set(), [PRIVATE]),
        ("_" + PRIVATE, set(), ["_" + PRIVATE]),
        ("[" + PRIVATE + "]", set(), [PRIVATE]),
        (" ".join([PRIVATE, PRIVATE.upper(), PRIVATE + ".git"]), set(), [PRIVATE]),
        (f"{PRIVATE} {CONFIGURED} {PRIVATE}", {CONFIGURED}, [PRIVATE, CONFIGURED]),
        (PRIVATE, {PRIVATE}, [PRIVATE]),
        ("-private", {"-private"}, ["-private"]),
        ("one.two", {"one.two"}, ["one.two"]),
    ],
)
def test_grammar(text: str, names: set[str], tokens: list[str]) -> None:
    assert list(checker.problems(text, names)) == [problem(token) for token in tokens]


def test_configuration() -> None:
    assert checker.configured_names("") == set()
    assert checker.configured_names(" , \n Foo.GIT, BAR \nfoo\n") == {"foo", "bar"}


def test_deduplication_resets_each_line(capsys: pytest.CaptureFixture[str]) -> None:
    assert checker.check_text(f"{PRIVATE} {PRIVATE}\n{PRIVATE}", set(), "text") == 2
    assert capsys.readouterr().out == (
        f"private_names: FAIL: text: {problem(PRIVATE)}\n" * 2
    )


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout.strip()


@pytest.fixture
def repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> str:
    monkeypatch.chdir(tmp_path)
    for name in (
        "PRIVATE_NAMES",
        "PRIVATE_NAMES_EXCLUDE",
        "BUILD_WORKSPACE_DIRECTORY",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_TEMPLATE_DIR", "")
    for kind in ("AUTHOR", "COMMITTER"):
        monkeypatch.setenv(f"GIT_{kind}_NAME", "Test")
        monkeypatch.setenv(f"GIT_{kind}_EMAIL", "test@example.invalid")
    git("init", "-q", "-b", "main")
    git("config", "core.hooksPath", os.devnull)
    git("config", "commit.gpgsign", "false")
    git("remote", "add", "origin", "https://example.invalid/public.git")
    Path("file.txt").write_text(PRIVATE + "\n", encoding="utf-8")
    return commit("base")


def commit(message: str) -> str:
    git("add", ".")
    git("commit", "-q", "--allow-empty", "-m", message)
    return git("rev-parse", "HEAD")


def run_checker(
    args: list[str],
    status: int,
    output: str | tuple[str, str],
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The import exercises branch coverage; the subprocess proves the real
    # command's exit status, stdout and stderr match the same contract.
    text = sys.stdin.read() if "--text" in args else ""
    stdout, stderr = (output, "") if isinstance(output, str) else output
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))
    assert checker.main(args) == status
    captured = capsys.readouterr()
    assert (captured.out, captured.err) == (stdout, stderr)
    result = subprocess.run(
        [sys.executable, str(Path(checker.__file__).resolve()), *args],
        input=text,
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode, result.stdout, result.stderr) == (status, stdout, stderr)


def test_clean_and_empty_range(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    commit("clean")
    run_checker(
        [repo, "HEAD"], 0, "private_names: 1 commits checked\n", capsys, monkeypatch
    )
    run_checker(
        ["HEAD", "HEAD"], 0, "private_names: 0 commits checked\n", capsys, monkeypatch
    )


def test_message_in_earlier_commit(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sha = commit("change\n\n" + PRIVATE)
    commit("clean tip")
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} message: {problem(PRIVATE)}\n"
        "private_names: 1 problems in 2 commits checked\n",
        capsys,
        monkeypatch,
    )


def test_added_line_even_when_removed_later(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    Path("added.txt").write_text("clean\n" + PRIVATE + "\n", encoding="utf-8")
    sha = commit("add")
    Path("added.txt").write_text("clean\n", encoding="utf-8")
    commit("remove")
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} added.txt:2: {problem(PRIVATE)}\n"
        "private_names: 1 problems in 2 commits checked\n",
        capsys,
        monkeypatch,
    )


def test_removed_line_passes(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    Path("file.txt").write_text("public\n", encoding="utf-8")
    commit("remove")
    run_checker(
        [repo, "HEAD"], 0, "private_names: 1 commits checked\n", capsys, monkeypatch
    )


def test_diff_headers_are_not_content(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    Path(PRIVATE).write_text("public\n", encoding="utf-8")
    commit("file")
    run_checker(
        [repo, "HEAD"], 0, "private_names: 1 commits checked\n", capsys, monkeypatch
    )


def test_added_content_starting_with_pluses(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    Path("new.txt").write_text("+++ " + PRIVATE + "\n", encoding="utf-8")
    sha = commit("content")
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} new.txt:1: {problem(PRIVATE)}\n"
        "private_names: 1 problems in 1 commits checked\n",
        capsys,
        monkeypatch,
    )


def test_configured_name(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PRIVATE_NAMES", CONFIGURED.upper() + ".git,unrelated\n")
    sha = commit(CONFIGURED)
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} message: {problem(CONFIGURED)}\n"
        "private_names: 1 problems in 1 commits checked\n",
        capsys,
        monkeypatch,
    )


@pytest.mark.parametrize(
    "origin",
    ["https://example.invalid/", "git@example.invalid:", "ssh://git@example.invalid/"],
)
@pytest.mark.parametrize("configured", [False, True])
def test_private_origin(
    repo: str,
    origin: str,
    configured: bool,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    name = CONFIGURED if configured else PRIVATE
    monkeypatch.setenv("PRIVATE_NAMES", CONFIGURED if configured else "")
    git("remote", "set-url", "origin", origin + name.upper() + ".git/")
    commit(PRIVATE)
    run_checker(
        [repo, "HEAD"],
        0,
        "private_names: skipped private repository\n",
        capsys,
        monkeypatch,
    )
    monkeypatch.setattr(sys, "stdin", io.StringIO(PRIVATE))
    run_checker(
        ["--text"],
        0,
        "private_names: skipped private repository\n",
        capsys,
        monkeypatch,
    )


def test_no_origin_and_caller_workspace(
    repo: str,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    git("remote", "remove", "origin")
    commit("clean")
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    monkeypatch.chdir(tmp_path.parent)
    run_checker(
        [repo, "HEAD"], 0, "private_names: 1 commits checked\n", capsys, monkeypatch
    )


@pytest.mark.parametrize("source", ["environment", "file", "both"])
def test_excluded_path(
    repo: str,
    source: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if source in {"file", "both"}:
        Path(".github").mkdir()
        Path(".github/private-names-exclude.txt").write_text(
            "# Fixture exclusions\n\n"
            "  # Reviewed checker fixture.  \n  testdata/*  \n\n"
            "# Another fixture directory.\nother/*\n",
            encoding="utf-8",
        )
        repo = commit("exclusions")
    Path("testdata").mkdir()
    Path("testdata/fixture.txt").write_text(PRIVATE, encoding="utf-8")
    if source == "both":
        Path("fixtures").mkdir()
        Path("fixtures/another.txt").write_text(PRIVATE, encoding="utf-8")
    if source in {"environment", "both"}:
        pattern = "testdata/*" if source == "environment" else "fixtures/*"
        monkeypatch.setenv("PRIVATE_NAMES_EXCLUDE", f" unused/*, {pattern}\n ")
    commit("fixture")
    if source in {"file", "both"}:
        # Neither the head nor an uncommitted edit can change the base's entry.
        Path(".github/private-names-exclude.txt").unlink()
        commit("remove exclusions")
        Path(".github/private-names-exclude.txt").write_text(
            "invalid/*\n", encoding="utf-8"
        )
    count = 1 if source == "environment" else 2
    # Read the base's file at the root even when invoked in a subdirectory.
    monkeypatch.chdir("testdata")
    run_checker(
        [repo, "HEAD"],
        0,
        f"private_names: {count} commits checked\n",
        capsys,
        monkeypatch,
    )
    sha = commit(PRIVATE)
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} message: {problem(PRIVATE)}\n"
        f"private_names: 1 problems in {count + 1} commits checked\n",
        capsys,
        monkeypatch,
    )
    monkeypatch.setattr(sys, "stdin", io.StringIO(PRIVATE))
    run_checker(
        ["--text"],
        1,
        f"private_names: FAIL: text: {problem(PRIVATE)}\n"
        "private_names: 1 problems in text checked\n",
        capsys,
        monkeypatch,
    )


@pytest.mark.parametrize("committed", [False, True])
def test_head_cannot_add_committed_exclusion(
    repo: str,
    committed: bool,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    Path("testdata").mkdir()
    Path("testdata/fixture.txt").write_text(PRIVATE, encoding="utf-8")
    Path(".github").mkdir()
    exclusion = Path(".github/private-names-exclude.txt")
    contents = "# Reviewed checker fixture.\ntestdata/*\n"
    if committed:
        exclusion.write_text(contents, encoding="utf-8")
    sha = commit("fixture")
    if not committed:
        exclusion.write_text(contents, encoding="utf-8")
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} testdata/fixture.txt:1: {problem(PRIVATE)}\n"
        "private_names: 1 problems in 1 commits checked\n",
        capsys,
        monkeypatch,
    )


@pytest.mark.parametrize(
    "contents",
    [
        "testdata/*\n",
        "# Reason\n\ntestdata/*\n",
        "#\ntestdata/*\n",
        "# Reason\ntestdata/*\nother/*\n",
    ],
)
def test_committed_exclusion_requires_reason(
    repo: str,
    contents: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    Path(".github").mkdir()
    Path(".github/private-names-exclude.txt").write_text(contents, encoding="utf-8")
    repo = commit("exclusions")
    # A valid head file cannot repair a malformed base file for this range.
    Path(".github/private-names-exclude.txt").write_text(
        "# Reviewed checker fixture.\ntestdata/*\n", encoding="utf-8"
    )
    commit("explain exclusions")
    # An environment exclusion cannot bypass validation of the committed file.
    monkeypatch.setenv("PRIVATE_NAMES_EXCLUDE", "*")
    run_checker(
        [repo, "HEAD"],
        1,
        (
            "",
            (
                f"private_names: FAIL: {repo}:.github/private-names-exclude.txt:"
                f"{len(contents.splitlines())}: "
                "exclusion glob requires a reason comment directly above it\n"
            ),
        ),
        capsys,
        monkeypatch,
    )
    monkeypatch.setattr(sys, "stdin", io.StringIO("public"))
    run_checker(
        ["--text"],
        0,
        "private_names: 0 problems in text checked\n",
        capsys,
        monkeypatch,
    )


@pytest.mark.parametrize("contents", [None, "", "# Heading\n\n # Comment\n \n"])
def test_empty_or_absent_committed_exclusions(
    repo: str,
    contents: str | None,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if contents is not None:
        Path(".github").mkdir()
        Path(".github/private-names-exclude.txt").write_text(contents, encoding="utf-8")
        repo = commit("exclusions")
    Path("new.txt").write_text(PRIVATE, encoding="utf-8")
    sha = commit("fixture")
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} new.txt:1: {problem(PRIVATE)}\n"
        "private_names: 1 problems in 1 commits checked\n",
        capsys,
        monkeypatch,
    )


@pytest.mark.parametrize("text", ["public\n", PRIVATE + "\n\n" + CONFIGURED])
def test_text(
    repo: str,
    text: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert repo
    monkeypatch.setenv("PRIVATE_NAMES", CONFIGURED)
    output = "private_names: 0 problems in text checked\n"
    status = 0
    if text.startswith(PRIVATE):
        status = 1
        output = (
            f"private_names: FAIL: text: {problem(PRIVATE)}\n"
            f"private_names: FAIL: text: {problem(CONFIGURED)}\n"
            "private_names: 2 problems in text checked\n"
        )
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))
    run_checker(["--text"], status, output, capsys, monkeypatch)


def test_merge_resolution_and_message(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PRIVATE_NAMES", CONFIGURED)
    git("checkout", "-qb", "topic")
    commit("topic change")
    git("checkout", "-q", "main")
    commit("main change")
    git("merge", "--no-ff", "--no-commit", "topic")
    Path("resolved.txt").write_text(PRIVATE, encoding="utf-8")
    sha = commit("merge\n\n" + CONFIGURED)
    run_checker(
        [repo, "HEAD"],
        1,
        f"private_names: FAIL: {sha} message: {problem(CONFIGURED)}\n"
        f"private_names: FAIL: {sha} resolved.txt:1: {problem(PRIVATE)}\n"
        "private_names: 2 problems in 3 commits checked\n",
        capsys,
        monkeypatch,
    )


def test_diff_parser() -> None:
    assert list(
        checker.added_lines(
            'diff --git a/a b/a\n--- a/a\n+++ "b/a\\tquote\\".txt"\n'
            "@@ -1 +2,3 @@\n-old\n+new\n context\n++++ content\n"
            "\\ No newline at end of file\n"
            "diff --git a/deleted b/deleted\n--- a/deleted\n+++ /dev/null\n"
            "@@ -1 +0,0 @@\n-old\n"
        )
    ) == [('a\tquote".txt', 2, "new"), ('a\tquote".txt', 4, "+++ content")]


@pytest.mark.parametrize("args", [[], ["HEAD"], ["--text", "HEAD"], ["A", "B", "C"]])
def test_invalid_arguments(args: list[str]) -> None:
    with pytest.raises(SystemExit) as caught:
        checker.main(args)
    assert caught.value.code == 2


def test_default_argv(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sys, "argv", ["private_names", repo, "HEAD"])
    assert checker.main() == 0
    assert capsys.readouterr().out == "private_names: 0 commits checked\n"


@pytest.mark.parametrize("base", ["missing", "--all"])
def test_invalid_revision(
    repo: str,
    base: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert checker.main([base, repo] if base != "--all" else ["--", base, repo]) == 1
    assert (
        capsys.readouterr().err
        == "private_names: FAIL: git cannot read the repository or range\n"
    )


def test_missing_git(
    repo: str,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PATH", "")
    assert checker.main([repo, "HEAD"]) == 1
    assert (
        capsys.readouterr().err
        == "private_names: FAIL: git cannot read the repository or range\n"
    )
