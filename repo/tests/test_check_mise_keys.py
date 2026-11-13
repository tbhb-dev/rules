# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for the mise.toml key comparison."""

lazy from pathlib import Path

lazy import pytest

from repo.tests import check_mise_keys as checker


def write(path: Path, text: str) -> Path:
    path.write_text(text)
    return path


def test_key_paths_nests_tables() -> None:
    assert checker.key_paths({"a": {"b": 1}, "c": 2}) == {"a", "a.b", "c"}


def test_is_excepted_matches_path_and_prefix() -> None:
    assert checker.is_excepted("tasks")
    assert checker.is_excepted("tasks.build")
    assert not checker.is_excepted("tasks_other")


def test_check_clean(tmp_path: Path) -> None:
    base = write(tmp_path / "base.toml", "[tools]\npython = '3'\n")
    mise = write(tmp_path / "mise.toml", "[tools]\npython = '4'\n")
    assert checker.check(base, mise) == []


def test_check_reports_both_directions(tmp_path: Path) -> None:
    base = write(tmp_path / "base.toml", "[tools]\nnode = '1'\n")
    mise = write(tmp_path / "mise.toml", "[tools]\ngo = '1'\n")
    errors = checker.check(base, mise)
    assert len(errors) == 2
    assert "tools.go is not in the baseline" in errors[0]
    assert "tools.node is in the baseline" in errors[1]


def test_check_skips_exceptions(tmp_path: Path) -> None:
    base = write(tmp_path / "base.toml", "[tools]\nnode = '1'\n")
    mise = write(
        tmp_path / "mise.toml", "[tools]\nnode = '1'\nuv = '1'\n[tasks.x]\nrun = 'y'\n"
    )
    assert checker.check(base, mise) == []


def test_main_exit_codes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    base = write(tmp_path / "base.toml", "[tools]\nnode = '1'\n")
    good = write(tmp_path / "good.toml", "[tools]\nnode = '1'\n")
    bad = write(tmp_path / "bad.toml", "[tools]\n")
    assert checker.main([str(base), str(good)]) == 0
    assert checker.main([str(base), str(bad)]) == 1
    assert capsys.readouterr().out == (
        f"{bad}: tools.node is in the baseline {base} but missing here\n"
    )
