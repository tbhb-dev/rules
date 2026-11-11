# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import os
import runpy
import sys
from pathlib import Path
from typing import cast

import pytest
import yaml

from lint.private.controls_changed import check_controls as checker

RULES = Path(checker.__file__).with_name("categories.json")
CATEGORIES = cast("list[checker.Category]", json.loads(RULES.read_text("utf-8")))
ERROR = "could not read Git range or control categories"
ROOT = Path(__file__).resolve().parents[3]


def commit(path: str, content: str) -> str:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    checker.git("git", "add", "--", path)
    checker.git("git", "commit", "-qm", "fixture")
    return checker.git("git", "rev-parse", "HEAD").strip()


@pytest.fixture
def repository(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    monkeypatch.chdir(repo)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_COUNT", "0")
    monkeypatch.setenv("GIT_AUTHOR_NAME", "test")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "test")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
    monkeypatch.delenv("SSH_AUTH_SOCK", raising=False)
    checker.git("git", "init", "-q")
    checker.git("git", "config", "core.hooksPath", str(tmp_path / "no-hooks"))
    commit("BUILD.bazel", 'py_test(name="unit", srcs=["first.py", "second.py"])\n')
    return repo


def test_one_commit_per_category_and_ordinary_source(
    repository: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert repository.is_dir()
    start = checker.git("git", "rev-parse", "HEAD").strip()
    cases = [
        (".vale.ini", "MinAlertLevel = error\n", "lint-format"),
        (".github/workflows/check.yml", "name: checks\n", "ci-workflows"),
        (".gitleaksignore", "fingerprint\n", "secret-scanning"),
        ("lib.py", "pass  # pragma: no cover\n", "coverage-mutation-pragmas"),
        (".pre-commit-config.yaml", "repos: []\n", "hooks"),
        (".github/CODEOWNERS", "* @example\n", "ownership-review"),
        ("BUILD.bazel", 'py_test(name="unit", srcs=["first.py"])\n', "test-lists"),
    ]
    for path, text, category in cases:
        commit(path, text)
        assert checker.main(["HEAD^", "HEAD"]) == 0
        assert capsys.readouterr().out == (
            f"{json.dumps(path)}\t{category}\ncontrols_changed: 1 paths, 1 categories\n"
        )
    before = checker.git("git", "rev-parse", "HEAD").strip()
    commit("ordinary.py", "answer = 42\n")
    assert checker.main(["--json", before, "HEAD"]) == 0
    assert capsys.readouterr().out == '{"categories": [], "error": null, "files": []}\n'
    assert checker.main([before, "HEAD"]) == 0
    assert capsys.readouterr().out == "controls_changed: 0 paths, 0 categories\n"
    expected: checker.Report = {
        "files": sorted(
            [{"path": path, "categories": [category]} for path, _, category in cases],
            key=lambda hit: hit["path"],
        ),
        "categories": sorted(category for _, _, category in cases),
        "error": None,
    }
    assert checker.main(["--json", start, "HEAD"]) == 0
    assert capsys.readouterr().out == json.dumps(expected, sort_keys=True) + "\n"
    assert checker.detect("git", "HEAD", "HEAD", CATEGORIES) == {
        "files": [],
        "categories": [],
        "error": None,
    }


@pytest.mark.parametrize(
    ("path", "category"),
    [
        (".vale.ini", "lint-format"),
        ("sub/.vale/project/Words.yml", "lint-format"),
        (".vale/config/vocabularies/project/accept.txt", "lint-format"),
        (".cspell-words.txt", "lint-format"),
        ("sub/cspell-words.txt", "lint-format"),
        (".cspell.jsonc", "lint-format"),
        (".cspell/project.txt", "lint-format"),
        (".rumdl.toml", "lint-format"),
        (".ryl.toml", "lint-format"),
        ("ruff.toml", "lint-format"),
        ("sub/.ruff.toml", "lint-format"),
        ("pyrefly.toml", "lint-format"),
        (".pylintrc", "lint-format"),
        ("sub/.golangci.yaml", "lint-format"),
        ("biome.jsonc", "lint-format"),
        (".github/workflows/check.yml", "ci-workflows"),
        (".github/actions/check/action.yml", "ci-workflows"),
        ("sub/.gitleaks.toml", "secret-scanning"),
        (".gitleaksignore", "secret-scanning"),
        (".pre-commit-config.yaml", "hooks"),
        ("hooks/check", "hooks"),
        ("nested/.githooks/pre-push", "hooks"),
        ("nested/.hooks/check", "hooks"),
        ("CODEOWNERS", "ownership-review"),
        ("docs/CODEOWNERS", "ownership-review"),
        (".github/CODEOWNERS", "ownership-review"),
        (".github/pull-request-sections.toml", "ownership-review"),
        (".github/settings.yml", "ownership-review"),
        (".github/rulesets/main.json", "ownership-review"),
    ],
)
def test_path_categories(path: str, category: str) -> None:
    assert [c["name"] for c in CATEGORIES if checker.matches(c, path, "", "")] == [
        category
    ]


@pytest.mark.parametrize(
    "package",
    ["Google", "write-good", "proselint", "ai-tells", "ai-tells-experimental"],
)
def test_synced_vale_packages_are_excluded(package: str) -> None:
    assert not checker.matches(CATEGORIES[0], f".vale/{package}/Words.yml", "", "new")


@pytest.mark.parametrize(
    "pragma",
    [
        "pragma: no cover",
        "pragma: no mutate",
        "//nolint:errcheck",
        "# noqa: S101",
        "# type: ignore[arg-type]",
        "eslint-disable-next-line",
        "pyrefly: ignore",
        "# nosec B603",
        "# shellcheck disable=SC2053",
        "# yamllint disable-line rule:line-length",
        "# buildifier: disable=bzl-visibility",
        "# zizmor: ignore[github-env]",
        "// gomutants:disable-next-line",
        "Stryker disable all",
        "istanbul ignore next",
        "c8 ignore start",
        "v8 ignore next",
    ],
)
def test_pragmas_only_on_added_lines(pragma: str) -> None:
    category = CATEGORIES[3]
    assert checker.matches(category, "source", "", pragma)
    assert not checker.matches(category, "source", pragma, "")
    assert not checker.matches(category, "source", pragma + "\nold", pragma + "\nnew")


def test_secret_pragma_and_multiple_categories() -> None:
    assert checker.matches(CATEGORIES[2], "source", "", "# gitleaks:allow")
    assert not checker.matches(CATEGORIES[2], "source", "# gitleaks:allow", "")
    assert checker.matches(CATEGORIES[2], "source", "", "+++ gitleaks:allow")
    assert checker.added_lines("a\nb\nc", "b\nc\nd") == "d"


@pytest.mark.parametrize("tool", ["ruff", "pyrefly", "pylint", '"pylint"', "'ruff'"])
def test_pyproject_sections(tool: str) -> None:
    old = f'[tool.{tool}.lint]\nignore = ["all"]\n[project]\nname = "old"\n'
    new = old.replace('name = "old"', 'name = "new"')
    assert not checker.matches(CATEGORIES[0], "nested/pyproject.toml", old, new)
    assert checker.matches(CATEGORIES[0], "pyproject.toml", old, "")
    assert checker.matches(CATEGORIES[0], "pyproject.toml", "", old)
    assert checker.matches(
        CATEGORIES[0], "pyproject.toml", old, old.replace("all", "one")
    )
    assert not checker.matches(
        CATEGORIES[0], "pyproject.toml", "", "[tool.ruff_extra]\nx=1"
    )
    assert not checker.matches(
        CATEGORIES[0], "pyproject.toml", "[project]\nx=1", "[project]\nx=2"
    )


@pytest.mark.parametrize(
    ("old", "new", "expected"),
    [
        (
            'py_test(name="unit", srcs=["a", "b"])',
            'py_test(name="unit", srcs=["b"])',
            True,
        ),
        ('py_test(name="unit")', "", True),
        (
            'py_test(name="unit", srcs=["a"])',
            'py_test(name="unit", srcs=["b", "a"])',
            False,
        ),
        (
            'py_test(name="unit", srcs=glob(["*.py"]))',
            'py_test(name="unit", srcs=glob(["*.py"]))',
            False,
        ),
        ('py_test(name="unit", srcs=FILES)', 'py_test(name="unit", srcs=OTHER)', True),
        ("", 'py_test(name="new", srcs=["a"])', False),
        ('cc_library(name="lib", srcs=["a"])', "", False),
        ('native.py_test(name="unit")', "", True),
        ('thing.cc_library(name="lib")', "", False),
        ('factory()(name="unit")', "", False),
        (
            'native.py_test(name="unit", srcs=["a", "b"])',
            'native.py_test(name="unit", srcs=["b"])',
            True,
        ),
        (
            'py_test(name="unit", srcs=files.ALL)',
            'py_test(name="unit", srcs=files.SOME)',
            True,
        ),
        ("py_test(name=NAME)", "", False),
        ("py_test(name=1)", "", False),
        ('py_test(srcs=["a"])', "", False),
        ('test_suite(name="suite")', "", True),
        ("invalid (", "", True),
        ("", "invalid (", True),
    ],
)
def test_removed_tests_and_sources(old: str, new: str, *, expected: bool) -> None:
    assert checker.matches(CATEGORIES[6], "BUILD.bazel", old, new) is expected
    assert checker.matches(CATEGORIES[6], "nested/BUILD", old, new) is expected


def test_deleted_renamed_and_dirty_files(repository: Path) -> None:
    commit(".gitleaks.toml", "[allowlist]\n")
    base = checker.git("git", "rev-parse", "HEAD").strip()
    checker.git("git", "mv", ".gitleaks.toml", "ordinary.toml")
    (repository / "BUILD.bazel").unlink()
    checker.git("git", "add", "-u")
    checker.git("git", "commit", "-qm", "rename and delete")
    (repository / ".vale.ini").write_text("dirty only", encoding="utf-8")
    assert checker.detect("git", base, "HEAD", CATEGORIES) == {
        "files": [
            {"path": ".gitleaks.toml", "categories": ["secret-scanning"]},
            {"path": "BUILD.bazel", "categories": ["test-lists"]},
        ],
        "categories": ["secret-scanning", "test-lists"],
        "error": None,
    }


def test_rename_only_flags_added_pragmas(
    repository: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    content = "# noqa\n" + "value = 1\n" * 20
    commit("old.py", content)
    base = checker.git("git", "rev-parse", "HEAD").strip()
    checker.git("git", "mv", "old.py", "new.py")
    checker.git("git", "commit", "-qm", "rename")
    assert checker.detect("git", base, "HEAD", CATEGORIES) == {
        "files": [],
        "categories": [],
        "error": None,
    }
    commit("new.py", content + "# pragma: no cover\n")
    assert checker.detect("git", base, "HEAD", CATEGORIES) == {
        "files": [{"path": "new.py", "categories": ["coverage-mutation-pragmas"]}],
        "categories": ["coverage-mutation-pragmas"],
        "error": None,
    }
    # A consumer may run Bazel in a nested workspace with diff.relative set.
    checker.git("git", "config", "diff.relative", "true")
    nested = repository / "nested"
    nested.mkdir()
    monkeypatch.chdir(nested)
    assert checker.detect("git", base, "HEAD", CATEGORIES)["files"] == [
        {"path": "new.py", "categories": ["coverage-mutation-pragmas"]}
    ]


def test_github_summary_and_annotations(
    repository: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert repository.is_dir()
    path = ".github/actions/<check%&>/a\nwarning.yml"
    commit(path, "# gitleaks:allow\n# noqa\n")
    summary = tmp_path / "summary"
    summary.write_text("earlier\n", encoding="utf-8")
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    assert checker.main(["--github", "HEAD^", "HEAD"]) == 0
    quoted = json.dumps(path)
    names = "ci-workflows,coverage-mutation-pragmas,secret-scanning"
    text = quoted + "\t" + names + "\ncontrols_changed: 1 paths, 3 categories"
    warnings = "".join(
        "::warning::" + category + ": " + quoted.replace("%", "%25") + "\n"
        for category in names.split(",")
    )
    assert capsys.readouterr().out == text + "\n" + warnings
    assert summary.read_text("utf-8") == (
        "earlier\n\n## Review controls changed\n\n<pre>\n"
        + text.replace("&", "&amp;").replace("<", "&lt;")
        + "\n</pre>\n"
    )
    assert checker.escape_annotation("%\r\n") == "%25%0D%0A"


@pytest.mark.parametrize("mode", [[], ["--json"], ["--github"]])
def test_unavailable_range_never_fails(
    repository: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    mode: list[str],
) -> None:
    assert repository.is_dir()
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "summary"))
    assert checker.main([*mode, "missing", "HEAD"]) == 0
    report: checker.Report = {"files": [], "categories": [], "error": ERROR}
    expected = "controls_changed: unavailable: " + ERROR + "\n"
    if mode == ["--json"]:
        expected = json.dumps(report, sort_keys=True) + "\n"
    if mode == ["--github"]:
        expected += "::warning::controls_changed: unavailable: " + ERROR + "\n"
    assert capsys.readouterr().out == expected


def test_cli_script_from_caller_checkout(
    repository: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert Path.cwd() == repository
    commit(".gitleaks.toml", "[allowlist]\n")
    monkeypatch.setattr(sys, "argv", [checker.__file__, "--json", "HEAD^", "HEAD"])
    # Keep mutation instrumentation in the test process while executing the
    # script entry point from a checkout without its own Python configuration.
    with pytest.raises(SystemExit) as exited:
        runpy.run_path(checker.__file__, run_name="__main__")
    assert exited.value.code == 0
    result = capsys.readouterr()
    assert result.out == (
        '{"categories": ["secret-scanning"], "error": null, '
        '"files": [{"categories": ["secret-scanning"], "path": ".gitleaks.toml"}]}\n'
    )
    assert result.err == ""


def test_workflow_contract() -> None:
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/repo-checks.yml").read_text("utf-8")
    )
    step = next(
        s
        for s in workflow["jobs"]["repo"]["steps"]
        if s["name"] == "Review controls changed"
    )
    assert step["if"] == "github.event_name == 'pull_request'"
    assert step["continue-on-error"] is True
    assert step["env"] == {
        "BASE_SHA": "${{ github.event.pull_request.base.sha }}",
        "HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
    }
    assert step["run"] == (
        "bazelisk run @tbhb_rules//lint:controls_changed -- --github "
        '"${BASE_SHA}" "${HEAD_SHA}" ||\n'
        '  echo "::warning::Review control detection could not run"\n'
    )


@pytest.mark.parametrize("destination", ["missing", "directory"])
def test_summary_unavailable_never_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    destination: str,
) -> None:
    if destination == "missing":
        monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    else:
        monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path))
    checker.github_output({"files": [], "categories": [], "error": None})
    assert (
        capsys.readouterr().out
        == "::warning::controls_changed: could not write step summary\n"
    )


def test_source_constants_and_suites() -> None:
    old = 'FILES = ["a", "b"]\npy_test(name="unit", srcs=FILES)'
    assert checker.matches(CATEGORIES[6], "BUILD", old, old.replace(', "b"', ""))
    assert not checker.matches(
        CATEGORIES[6], "BUILD", old, old.replace('["a", "b"]', '["b", "a", "c"]')
    )
    chain = 'FILES = OTHER\nOTHER = ["a", "b"]\npy_test(name="unit", srcs=FILES)'
    assert checker.matches(CATEGORIES[6], "BUILD", chain, chain.replace(', "b"', ""))
    cycle = 'FILES = OTHER\nOTHER = FILES\npy_test(name="unit", srcs=FILES)'
    assert not checker.matches(CATEGORIES[6], "BUILD", cycle, cycle)
    tuples = "a, b = [1, 2]\n"
    assert not checker.matches(CATEGORIES[6], "BUILD", tuples, "")
    suite = 'test_suite(name="suite", tests=[":one", ":two"])'
    assert checker.matches(CATEGORIES[6], "BUILD", suite, suite.replace(', ":two"', ""))


def test_added_lines_preserve_repeated_context() -> None:
    assert checker.added_lines("old\nvalue", "new\nlines") == "new\nlines"
    repeated = "repeated\n" * 300
    assert (
        checker.added_lines("old\n" + repeated + "end", "new\n" + repeated + "last")
        == "new\nlast"
    )


def test_sections_preserve_names_and_ignore_preamble() -> None:
    assert checker.sections(
        "# preamble\n[tool.ruff]\na=1\n[tool.pylint]\nb=2\n", r"^tool\."
    ) == {
        "tool.ruff": ["[tool.ruff]", "a=1"],
        "tool.pylint": ["[tool.pylint]", "b=2"],
    }
    assert checker.sections("preamble\n[project]\nname='demo'", "^$") == {
        "": ["preamble"]
    }


def test_source_expression_changes_and_unnamed_calls() -> None:
    before = 'FILES = ["a"]\npy_test(name="unit", srcs=FILES)'
    after = 'FILES = ["a"]\npy_test(name="unit", srcs=["a"])'
    assert checker.matches(CATEGORIES[6], "BUILD", before, after)
    before = 'py_test(name=NAME)\npy_test(name="unit", srcs=["a"])'
    assert checker.matches(CATEGORIES[6], "BUILD", before, "py_test(name=NAME)")
    category: checker.Category = {
        "name": "tests",
        "paths": [],
        "removed_test_calls": "^py_test$",
    }
    assert checker.matches(category, "BUILD", before, "")
    assert checker.matches(
        category,
        "BUILD",
        'py_test(name="unit", srcs=["a", "b"])',
        'py_test(name="unit", srcs=["a"])',
    )
    assert not checker.matches(CATEGORIES[0], "ordinary.toml", "", "[tool.ruff]")
    assert not checker.matches(CATEGORIES[1], "pyproject.toml", "", "[tool.ruff]")


def test_git_preserves_non_utf8_content(repository: Path) -> None:
    path = repository / os.fsdecode(b"source-\xff.py")
    path.write_bytes(b"value = '\xff'\n# noqa\n")
    checker.git("git", "add", "--", str(path))
    checker.git("git", "commit", "-qm", "non UTF-8 fixture")
    assert checker.detect("git", "HEAD^", "HEAD", CATEGORIES)["files"] == [
        {"path": path.name, "categories": ["coverage-mutation-pragmas"]}
    ]


def test_explicit_range_and_empty_blobs(repository: Path) -> None:
    assert repository.is_dir()
    base = checker.git("git", "rev-parse", "HEAD").strip()
    head = commit("new.py", "XXXX")
    commit("later.py", "XXXX")
    category: checker.Category = {"name": "literal", "paths": [], "added": ["^XXXX$"]}
    assert checker.detect("git", base, head, [category]) == {
        "files": [{"path": "new.py", "categories": ["literal"]}],
        "categories": ["literal"],
        "error": None,
    }


def test_multiple_paths_in_one_annotation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    summary = tmp_path / "summary"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    checker.github_output(
        {
            "files": [
                {"path": ".vale.ini", "categories": ["lint-format"]},
                {"path": ".cspell.jsonc", "categories": ["lint-format"]},
            ],
            "categories": ["lint-format"],
            "error": None,
        }
    )
    assert capsys.readouterr().out == (
        '::warning::lint-format: ".vale.ini", ".cspell.jsonc"\n'
    )


def test_cli_help(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as exited:
        checker.main(["--help"])
    assert exited.value.code == 0
    help_text = capsys.readouterr().out
    assert (
        "Report changes to review controls without making them a merge gate."
        in help_text
    )
    help_lines = [" ".join(line.split()) for line in help_text.splitlines()]
    assert "--json emit a JSON report" in help_lines
    assert "--github write summary and warnings" in help_lines
    assert "--git" not in help_text.split()
