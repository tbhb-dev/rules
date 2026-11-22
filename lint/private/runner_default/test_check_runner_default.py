# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from typing import TYPE_CHECKING

import pytest

from lint.private.runner_default import check_runner_default as checker

if TYPE_CHECKING:
    from pathlib import Path

HOSTED = "ubuntu-26.04"
EXPRESSION = checker.EXPRESSION
CALLER = "{workflow_call: {inputs: {runs-on: {type: string%s}}}}"


def resolve(inp: str, private: bool, label: str) -> str:
    """Evaluate the expression with GitHub's short-circuit string semantics."""
    python = (
        EXPRESSION.removeprefix("${{")
        .removesuffix("}}")
        .replace("||", " or ")
        .replace("&&", " and ")
        .replace("inputs.runs-on", "inp")
        .replace("github.event.repository.private", "private")
        .replace("vars.PRIVATE_RUNNER_LABEL", "label")
    )
    return str(eval(python, {}, {"inp": inp, "private": private, "label": label}))  # noqa: S307


@pytest.mark.parametrize(
    ("inp", "private", "label", "expected"),
    [
        ("", False, "", HOSTED),
        ("", False, "private-runner", HOSTED),
        ("", True, "", HOSTED),
        ("", True, "private-runner", "private-runner"),
        ("explicit", False, "", "explicit"),
        ("explicit", True, "private-runner", "explicit"),
    ],
)
def test_expression(inp: str, private: bool, label: str, expected: str) -> None:
    assert resolve(inp, private, label) == expected


@pytest.mark.parametrize(
    "case",
    [
        (CALLER % "", f"runs-on: {EXPRESSION!r}", ""),
        (CALLER % ", default: ubuntu-26.04", f"runs-on: {EXPRESSION!r}", "input"),
        (CALLER % "", "runs-on: ubuntu-26.04", "job"),
        ("push", "runs-on: ubuntu-26.04", ""),
        ("push", f"runs-on: {EXPRESSION!r}", ""),
        ("push", "runs-on: '${{ vars.PRIVATE_RUNNER_LABEL }}'", "job"),
        (CALLER % "", "uses: ./.github/workflows/build.yml", ""),
    ],
)
def test_runner_default(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    case: tuple[str, str, str],
) -> None:
    on, job, output = case
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("BUILD_WORKSPACE_DIRECTORY", raising=False)
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "ci.yml").write_text(
        f"on: {on}\njobs:\n  build: {{{job}}}\n", encoding="utf-8"
    )
    result = checker.main()
    printed = capsys.readouterr().out
    assert result == (1 if output else 0)
    if output:
        assert printed.startswith(f".github/workflows/ci.yml: {output}")
    else:
        assert not printed
