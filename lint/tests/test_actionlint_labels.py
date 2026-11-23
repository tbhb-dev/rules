# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from typing import TYPE_CHECKING

import pytest

from lint.private import check_actionlint_labels as checker

if TYPE_CHECKING:
    from pathlib import Path

HOSTED = "ubuntu-26.04"
ARM = "ubuntu-26.04-arm"
LABELS = "self-hosted-runner: {labels: [%s]}\n"


@pytest.fixture
def config(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    baseline = tmp_path / "baseline.yaml"
    baseline.write_text(LABELS % f"{HOSTED}, {ARM}", encoding="utf-8")
    monkeypatch.setattr(checker, "BASELINE_PATH", baseline)
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    path = tmp_path / checker.CONFIG_PATH
    path.parent.mkdir()
    return path


@pytest.mark.parametrize(
    ("contents", "missing"),
    [
        (LABELS % f"{ARM}, {HOSTED}", ""),
        (LABELS % "", f"{HOSTED}, {ARM}"),
        (LABELS % ARM, HOSTED),
        (LABELS % f"{HOSTED}, {ARM}, custom-runner, on", ""),
        ("{}\n", f"{HOSTED}, {ARM}"),
        ("self-hosted-runner: {}\n", f"{HOSTED}, {ARM}"),
    ],
)
def test_labels(
    config: Path, contents: str, missing: str, capsys: pytest.CaptureFixture[str]
) -> None:
    config.write_text(contents, encoding="utf-8")
    assert checker.main() == (1 if missing else 0)
    expected = (
        f".github/actionlint.yaml is missing runner labels: {missing}. "
        "Copy them from the baseline's .github/actionlint.yaml.\n"
        if missing
        else ""
    )
    assert capsys.readouterr().out == expected


@pytest.mark.usefixtures("config")
def test_no_config(capsys: pytest.CaptureFixture[str]) -> None:
    assert checker.main() == 0
    assert capsys.readouterr() == ("", "")


def test_malformed_yaml(config: Path, capsys: pytest.CaptureFixture[str]) -> None:
    config.write_text("self-hosted-runner: {labels: [\n", encoding="utf-8")
    assert checker.main() == 1
    error = capsys.readouterr().err
    assert error.startswith("Invalid actionlint YAML.")
    assert str(config) in error


def test_unreadable_config(config: Path, capsys: pytest.CaptureFixture[str]) -> None:
    config.mkdir()
    assert checker.main() == 1
    assert capsys.readouterr().err.startswith(
        "Could not read actionlint runner labels."
    )
