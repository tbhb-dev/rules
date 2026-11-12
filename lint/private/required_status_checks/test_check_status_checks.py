# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for ruleset contexts and CI conclusion dependencies."""

import json
import sys
from pathlib import Path

import pytest

from lint.private.required_status_checks import check_status_checks as checker

ROOT = Path(__file__).resolve().parents[3]


@pytest.fixture
def files(tmp_path: Path) -> tuple[Path, Path]:
    ruleset = tmp_path / "main.json"
    workflow = tmp_path / "ci.yml"
    ruleset.write_text(
        json.dumps(
            {
                "rules": [
                    {"type": "deletion"},
                    {
                        "type": "required_status_checks",
                        "parameters": {
                            "required_status_checks": [{"context": "conclusion"}],
                        },
                    },
                ],
            }
        ),
        encoding="utf-8",
    )
    workflow.write_text(
        "jobs:\n"
        "  cache-warm: {}\n"
        "  plan: {name: planning}\n"
        "  apple: {name: 'apple (apple-smoke)'}\n"
        "  conclusion: {needs: [plan, apple]}\n",
        encoding="utf-8",
    )
    return ruleset, workflow


def contexts(path: Path, names: list[str]) -> None:
    path.write_text(
        json.dumps(
            {
                "rules": [
                    {
                        "type": "required_status_checks",
                        "parameters": {
                            "required_status_checks": [
                                {"context": name} for name in names
                            ],
                        },
                    },
                ],
            }
        ),
        encoding="utf-8",
    )


def test_real_files_pass(capsys: pytest.CaptureFixture[str]) -> None:
    assert (
        checker.main(
            [
                str(ROOT / ".github/rulesets/main.json"),
                str(ROOT / ".github/workflows/ci.yml"),
            ]
        )
        == 0
    )
    assert capsys.readouterr().out == (
        "OK: required statuses and CI conclusion dependencies agree\n"
    )


def test_fallback_to_job_id_and_valid_exemption(files: tuple[Path, Path]) -> None:
    assert checker.check(*files) == []
    assert checker.EXEMPT_JOBS["cache-warm"] == (
        "Runs only on pushes to main, never on a pull request."
    )


def test_conclusion_display_name(files: tuple[Path, Path]) -> None:
    ruleset, workflow = files
    contexts(ruleset, ["CI gate"])
    workflow.write_text(
        workflow.read_text(encoding="utf-8").replace(
            "conclusion: {needs:", "conclusion: {name: CI gate, needs:"
        ),
        encoding="utf-8",
    )
    assert checker.check(*files) == []
    contexts(ruleset, ["conclusion"])
    assert checker.check(*files) == [
        f"{ruleset.as_posix()}: required context 'conclusion' has no matching CI job"
    ]


@pytest.mark.parametrize("name", ["unknown", "apple", "plan", ""])
def test_context_without_matching_name(files: tuple[Path, Path], name: str) -> None:
    ruleset, _ = files
    contexts(ruleset, [name])
    assert checker.check(*files) == [
        f"{ruleset.as_posix()}: required context {name!r} has no matching CI job"
    ]


@pytest.mark.parametrize(
    ("name", "job_id"), [("apple (apple-smoke)", "apple"), ("planning", "plan")]
)
def test_matching_job_must_be_conclusion(
    files: tuple[Path, Path], name: str, job_id: str
) -> None:
    ruleset, _ = files
    contexts(ruleset, [name])
    assert checker.check(*files) == [
        (
            f"{ruleset.as_posix()}: required context {name!r} matches job {job_id!r}, "
            "expected 'conclusion'"
        )
    ]


def test_all_contexts_and_duplicate_names_are_checked(files: tuple[Path, Path]) -> None:
    ruleset, workflow = files
    contexts(ruleset, ["conclusion", "missing"])
    workflow.write_text(
        workflow.read_text(encoding="utf-8").replace(
            "name: planning", "name: conclusion"
        ),
        encoding="utf-8",
    )
    assert checker.check(*files) == [
        (
            f"{ruleset.as_posix()}: required context 'conclusion' matches job 'plan', "
            "expected 'conclusion'"
        ),
        f"{ruleset.as_posix()}: required context 'missing' has no matching CI job",
    ]


@pytest.mark.parametrize(
    "text",
    [
        '{"rules": [{"type": "required_status_checks"}]}',
        '{"rules": [{"type": "required_status_checks", "parameters": {}}]}',
    ],
)
def test_missing_required_contexts(files: tuple[Path, Path], text: str) -> None:
    ruleset, _ = files
    ruleset.write_text(text, encoding="utf-8")
    assert checker.check(*files) == [
        f"{ruleset.as_posix()}: required_status_checks is empty"
    ]


def test_empty_context_list(files: tuple[Path, Path]) -> None:
    ruleset, _ = files
    contexts(ruleset, [])
    assert checker.check(*files) == [
        f"{ruleset.as_posix()}: required_status_checks is empty"
    ]


@pytest.mark.parametrize(
    "text", ["{}", '{"rules": []}', '{"rules": [{"type": "deletion"}]}']
)
def test_missing_rule(files: tuple[Path, Path], text: str) -> None:
    ruleset, _ = files
    ruleset.write_text(text, encoding="utf-8")
    assert checker.check(*files) == [
        f"{ruleset.as_posix()}: no required_status_checks rule"
    ]


@pytest.mark.parametrize("needs", ["[]", "[planning, 'apple (apple-smoke)']"])
def test_needs_reports_each_missing_job_id(
    files: tuple[Path, Path], needs: str
) -> None:
    _, workflow = files
    workflow.write_text(
        workflow.read_text(encoding="utf-8").replace("[plan, apple]", needs),
        encoding="utf-8",
    )
    assert checker.check(*files) == [
        f"{workflow.as_posix()}: conclusion needs is missing job 'apple'",
        f"{workflow.as_posix()}: conclusion needs is missing job 'plan'",
    ]


def test_needs_must_be_a_list(files: tuple[Path, Path]) -> None:
    _, workflow = files
    workflow.write_text(
        "jobs: {cache-warm: {}, conclusion: {needs: cache-warm}}\n", encoding="utf-8"
    )
    assert checker.check(*files) == [
        f"{workflow.as_posix()}: conclusion needs must be a list of job ids"
    ]


def test_missing_needs_defaults_to_empty(files: tuple[Path, Path]) -> None:
    _, workflow = files
    workflow.write_text(
        "jobs: {cache-warm: {}, plan: {}, conclusion: {}}\n", encoding="utf-8"
    )
    assert checker.check(*files) == [
        f"{workflow.as_posix()}: conclusion needs is missing job 'plan'"
    ]


def test_nonexistent_exemption_is_a_failure(files: tuple[Path, Path]) -> None:
    _, workflow = files
    workflow.write_text(
        workflow.read_text(encoding="utf-8").replace("  cache-warm: {}\n", ""),
        encoding="utf-8",
    )
    assert checker.check(*files) == [
        f"{workflow.as_posix()}: exempt job 'cache-warm' does not exist"
    ]


@pytest.mark.parametrize("text", ["jobs: {cache-warm: {}}\n", "{}\n"])
def test_missing_conclusion(files: tuple[Path, Path], text: str) -> None:
    ruleset, workflow = files
    workflow.write_text(text, encoding="utf-8")
    errors = checker.check(*files)
    assert errors[0] == (
        f"{ruleset.as_posix()}: required context 'conclusion' has no matching CI job"
    )
    assert errors[-1] == f"{workflow.as_posix()}: conclusion job does not exist"


@pytest.mark.parametrize("index", [0, 1])
@pytest.mark.parametrize("content", [None, b"\xff", b"{\ninvalid: [\n"])
def test_read_and_parse_errors_are_one_line_with_path(
    files: tuple[Path, Path], index: int, content: bytes | None
) -> None:
    path = files[index]
    if content is None:
        path.unlink()
    else:
        path.write_bytes(content)
    errors = checker.check(*files)
    assert len(errors) == 1
    assert errors[0].startswith(f"{path.as_posix()}: ")
    assert len(errors[0].splitlines()) == 1


def test_main_prints_each_failure(
    files: tuple[Path, Path],
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ruleset, _ = files
    contexts(ruleset, ["first", "second"])
    monkeypatch.setattr(sys, "argv", ["check_status_checks.py", *map(str, files)])
    assert checker.main() == 1
    assert capsys.readouterr().out == (
        f"{ruleset.as_posix()}: required context 'first' has no matching CI job\n"
        f"{ruleset.as_posix()}: required context 'second' has no matching CI job\n"
    )


def test_main_help(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as caught:
        checker.main(["--help"])
    assert caught.value.code == 0
    assert "ruleset workflow" in capsys.readouterr().out
