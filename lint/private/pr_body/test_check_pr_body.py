# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import io
import json
import re
import sys
import tomllib
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, ValidationError

from lint.private.pr_body import check_pr_body as lint

ROOT = Path(__file__).resolve().parents[3]
BASELINE = ROOT / "repo/baseline"
POLICY = ".github/definition-of-done.toml"
SECTIONS = ".github/pull-request-sections.toml"
REQUIRED = ["Why", "Behavior change", "Verification"]
BODY = "## Why\nA policy gap.\n## Behavior change\nApply the floor.\n## Verification\n"
HEAD = "a" * 40
OLD_HEAD = "b" * 40


def test_floor_matches_manifest_and_repository() -> None:
    manifest = tomllib.loads((BASELINE / "manifest.toml").read_text(encoding="utf-8"))
    [entry] = [entry for entry in manifest["file"] if entry["path"] == POLICY]
    assert entry["mode"] == "keys"
    assert entry["visibility"] == "all"
    for kind in manifest["kind"].values():
        assert POLICY in kind["required"]
    schema = json.loads(lint.SCHEMA.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    baseline = BASELINE / entry["source"]
    floor = tomllib.loads(baseline.read_text(encoding="utf-8"))
    assert set(entry["keys"]) == set(floor) == set(schema["required"])
    assert lint.conclusion_check(baseline) == "conclusion"
    assert baseline.read_bytes() == (ROOT / POLICY).read_bytes()
    template = ".github/PULL_REQUEST_TEMPLATE.md"
    assert (BASELINE / "files" / template).read_bytes() == (
        ROOT / template
    ).read_bytes()


@pytest.mark.parametrize(
    ("key", "replacement"),
    [
        ("schema_version", "2"),
        ("review_at_head", "false"),
        ("conclusion_check", '"other"'),
        ("require_pr_sections", "false"),
        ("no_ci_restatement", "false"),
    ],
)
def test_floor_cannot_be_removed_or_weakened(
    tmp_path: Path, key: str, replacement: str
) -> None:
    source = (BASELINE / "files" / POLICY).read_text(encoding="utf-8")
    policy = tmp_path / "policy.toml"
    policy.write_text(
        re.sub(rf"^{key}.*$", "", source, flags=re.MULTILINE), encoding="utf-8"
    )
    with pytest.raises(ValidationError, match=key):
        lint.conclusion_check(policy)
    disabled = re.sub(
        rf"^{key}.*$", f"{key} = {replacement}", source, flags=re.MULTILINE
    )
    policy.write_text(disabled, encoding="utf-8")
    with pytest.raises(ValidationError, match="was expected"):
        lint.conclusion_check(policy)


def test_repository_can_extend_floor(tmp_path: Path) -> None:
    policy = tmp_path / "policy.toml"
    source = (ROOT / POLICY).read_text(encoding="utf-8")
    policy.write_text(source + "require_manual_review = true\n", encoding="utf-8")
    assert lint.conclusion_check(policy) == "conclusion"


@pytest.mark.parametrize(
    "claim",
    [
        "CI passed.",
        "All checks are green.",
        "All checks green",
        "Tests pass: 125",
        "Tests passed (125).",
        "1,250 tests passed.",
        "- `conclusion`",
        "1. **bazel (ubuntu-26.04, root)**",
        "- bazel (ubuntu-26.04, root): success",
        "The CI check bazel (ubuntu-26.04, root) is visible.",
        "Passed conclusion.",
    ],
)
def test_ci_restatement(claim: str) -> None:
    names = ["conclusion", "bazel (ubuntu-26.04, root)"]
    assert lint.body_findings(BODY + claim, REQUIRED, names) == [
        "Verification line 6 restates CI. List only checks CI does not show."
    ]


def test_only_verification_counts_and_local_checks_are_allowed() -> None:
    body = (
        BODY.replace("A policy gap.", "CI passed on the previous head.")
        + "<!--\nCI passed\n-->\n\n"
        "- Ran `bazelisk test //repo/...` locally.\n"
        "- The archive contained a local fixture.\n"
        "- The extra tests passed.\n"
        "## Risk\nCI passed.\n"
    )
    assert lint.body_findings(body, REQUIRED, ["conclusion", "repo", "archive"]) == []


def test_markdown_sections() -> None:
    body = (
        "<!-- ## Why -->\n"
        "```markdown\n## Why\n~~~\n````still code\n## Why\n```\n"
        "## Behavior change ##\n\n"
        "## Verification\r\n### Manual checks\r\nCI passed\r\n"
        "# End\nCI passed\n"
    )
    assert lint.body_findings(body, REQUIRED, ["conclusion"]) == [
        "Missing required section 'Why'.",
        "Verification line 12 restates CI. List only checks CI does not show.",
    ]


@pytest.fixture(autouse=True)
def use_repository(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(ROOT))
    monkeypatch.setattr(sys, "stdin", io.StringIO(BODY))


def test_body_command_checks_custom_check_names(
    capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sys, "stdin", io.StringIO(BODY + "lint / vale"))
    assert lint.main(["body", "--check-name", "lint / vale"]) == 1
    assert "Verification line 6 restates CI" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("review", "check_evidence", "expected"),
    [
        (HEAD, ["conclusion", HEAD, "success"], ""),
        (OLD_HEAD, ["conclusion", HEAD, "success"], "no review evidence"),
        (HEAD, ["conclusion", OLD_HEAD, "success"], "must succeed"),
        (HEAD, ["conclusion", HEAD, "failure"], "must succeed"),
        (HEAD, ["other", HEAD, "success"], "must succeed"),
    ],
)
def test_definition_of_done(
    capsys: pytest.CaptureFixture[str],
    review: str,
    check_evidence: list[str],
    expected: str,
) -> None:
    args = ["done", "--head", HEAD, "--reviewed-head", review]
    args += ["--conclusion", *check_evidence]
    assert lint.main(args) == bool(expected)
    errors = capsys.readouterr().err
    assert len(errors.splitlines()) == bool(expected)
    assert expected in errors


def test_missing_evidence(capsys: pytest.CaptureFixture[str]) -> None:
    assert lint.main(["done", "--head", HEAD]) == 1
    errors = capsys.readouterr().err
    assert "no review evidence" in errors
    assert "must succeed" in errors


def test_abbreviated_head(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as error:
        lint.main(["done", "--head", "a123"])
    assert error.value.code == 2
    assert "full Git commit SHA" in capsys.readouterr().err


def test_unreadable_configuration(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    assert lint.main(["body", "--policy", str(tmp_path / "missing.toml")]) == 2
    assert "missing.toml" in capsys.readouterr().err
