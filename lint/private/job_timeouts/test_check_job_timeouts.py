# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from typing import TYPE_CHECKING

import pytest

from lint.private.job_timeouts import check_job_timeouts as checker

if TYPE_CHECKING:
    from pathlib import Path


@pytest.mark.parametrize("extension", ["yml", "yaml"])
@pytest.mark.parametrize(
    "case",
    [
        (
            "runs-on: ubuntu-26.04, steps: [{run: echo ok}]",
            1,
            "job 'build' lacks timeout-minutes\n",
        ),
        (
            (
                "runs-on: ubuntu-26.04, timeout-minutes: 30, "
                "steps: [{uses: './.github/actions/build'}]"
            ),
            0,
            "",
        ),
        ("uses: './.github/workflows/build.yml'", 0, ""),
    ],
)
def test_job_timeouts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    extension: str,
    case: tuple[str, int, str],
) -> None:
    job, status, output = case
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("BUILD_WORKSPACE_DIRECTORY", raising=False)
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    path = workflows / f"ci.{extension}"
    path.write_text(
        "jobs:\n"
        "  ready: {runs-on: ubuntu-26.04, timeout-minutes: 10}\n"
        f"  build: {{{job}}}\n",
        encoding="utf-8",
    )
    result = checker.main()
    expected = f".github/workflows/ci.{extension}: {output}" if output else ""
    assert capsys.readouterr().out == expected
    assert result == status


def test_bazel_run_checks_callers_workspace(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    path = workflows / "ci.yml"
    path.write_text("jobs: {consumer: {runs-on: ubuntu-26.04}}\n", encoding="utf-8")
    assert checker.main() == 1
    assert capsys.readouterr().out == (
        ".github/workflows/ci.yml: job 'consumer' lacks timeout-minutes\n"
    )
