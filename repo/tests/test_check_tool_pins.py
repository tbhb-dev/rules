# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Tests for the tools.json and extensions.bzl pin comparison."""

lazy import json
lazy from pathlib import Path

lazy import pytest

from repo.tests import check_tool_pins as checker

URL = "https://example.test/cue/v1.2.3/cue_v1.2.3_linux_amd64.tar.gz"
SHA = "ab" * 32

BZL = f"""
    http_archive(
        name = "tbhb_rules_cue_linux_x86_64",
        build_file_content = _EXPORT.format("cue"),
        sha256 = "{SHA}",
        url = "{URL}",
    )
"""


def write(tmp_path: Path, pin: dict[str, str], bzl: str = BZL) -> tuple[Path, Path]:
    tools = tmp_path / "tools.json"
    tools.write_text(
        json.dumps({"cue": {"version": "1.2.3", "platforms": {"linux_amd64": pin}}})
    )
    extensions = tmp_path / "extensions.bzl"
    extensions.write_text(bzl)
    return tools, extensions


def test_bzl_pins_maps_platform_names() -> None:
    assert checker.bzl_pins(BZL) == {
        "cue": {"linux_amd64": {"url": URL, "sha256": SHA}}
    }


def test_check_clean(tmp_path: Path) -> None:
    assert checker.check(*write(tmp_path, {"url": URL, "sha256": SHA})) == []


def test_check_reports_a_differing_sha(tmp_path: Path) -> None:
    errors = checker.check(*write(tmp_path, {"url": URL, "sha256": "cd" * 32}))
    assert len(errors) == 1
    assert "cue linux_amd64 differs" in errors[0]


def test_check_reports_a_missing_archive(tmp_path: Path) -> None:
    errors = checker.check(*write(tmp_path, {"url": URL, "sha256": SHA}, bzl=""))
    assert len(errors) == 1
    assert errors[0].endswith("None")


def test_check_reports_a_url_without_the_version(tmp_path: Path) -> None:
    other = URL.replace("v1.2.3", "v9.9.9")
    bzl = BZL.replace(URL, other)
    errors = checker.check(*write(tmp_path, {"url": other, "sha256": SHA}, bzl=bzl))
    assert errors == [
        f"{tmp_path / 'tools.json'}: cue linux_amd64 url does not carry version 1.2.3"
    ]


def test_main_exit_codes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    tools, extensions = write(tmp_path, {"url": URL, "sha256": SHA})
    assert checker.main([str(tools), str(extensions)]) == 0
    tools, extensions = write(tmp_path, {"url": URL, "sha256": "cd" * 32})
    assert checker.main([str(tools), str(extensions)]) == 1
    assert "differs" in capsys.readouterr().out
