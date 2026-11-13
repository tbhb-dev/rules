# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Exercise JSON validation, permissions, server references and the CLI."""

import json
import re
import sys
from typing import TYPE_CHECKING

import pytest

from lint.private.claude_settings import check_claude_settings as checker

if TYPE_CHECKING:
    import pathlib

DENIED = [f"Bash(gh pr {operation}:*)" for operation in ("create", "edit", "merge")]


def valid_settings() -> dict[str, object]:
    return {
        "permissions": {"deny": DENIED, "allow": ["mcp__demo"]},
        "enabledMcpjsonServers": ["demo"],
    }


def write_configs(
    root: pathlib.Path, settings: object, mcp: object
) -> tuple[pathlib.Path, pathlib.Path]:
    settings_path = root / "settings.json"
    mcp_path = root / "mcp.json"
    settings_path.write_text(json.dumps(settings), encoding="utf-8")
    mcp_path.write_text(json.dumps(mcp), encoding="utf-8")
    return settings_path, mcp_path


def test_valid_dynamic_servers_and_extra_denials(tmp_path: pathlib.Path) -> None:
    names = ["alpha", "beta-2", "server_with_underscores"]
    settings = {
        "permissions": {
            "deny": [*DENIED, "Bash(other:*)"],
            "allow": ["Read", "mcp_other", *("mcp__" + name for name in names)],
        },
        "enabledMcpjsonServers": names[:2],
    }
    mcp = {"mcpServers": dict.fromkeys(names, None)}
    assert checker.check(*write_configs(tmp_path, settings, mcp)) == []


def test_empty_server_lists_pass(tmp_path: pathlib.Path) -> None:
    empty: list[str] = []
    settings = {
        "permissions": {"deny": DENIED, "allow": empty},
        "enabledMcpjsonServers": empty,
    }
    assert checker.check(*write_configs(tmp_path, settings, {"mcpServers": {}})) == []


@pytest.mark.parametrize("entry", DENIED)
def test_each_required_denial(tmp_path: pathlib.Path, entry: str) -> None:
    settings = valid_settings()
    settings["permissions"] = {
        "deny": [value for value in DENIED if value != entry],
        "allow": ["mcp__demo"],
    }
    paths = write_configs(tmp_path, settings, {"mcpServers": {"demo": {}}})
    assert checker.check(*paths) == [f"{paths[0]}: permissions.deny missing {entry!r}"]


def test_enabled_server_requires_allow_entry(tmp_path: pathlib.Path) -> None:
    settings = valid_settings()
    settings["permissions"] = {"deny": DENIED, "allow": ["Read"]}
    paths = write_configs(tmp_path, settings, {"mcpServers": {"demo": {}}})
    assert checker.check(*paths) == [
        f"{paths[0]}: permissions.allow missing 'mcp__demo' for enabled server"
    ]


def test_enabled_and_allowed_undefined_servers_are_both_reported(
    tmp_path: pathlib.Path,
) -> None:
    paths = write_configs(tmp_path, valid_settings(), {"mcpServers": {}})
    assert checker.check(*paths) == [
        f"{paths[0]}: enabledMcpjsonServers server 'demo' undefined in mcpServers",
        f"{paths[0]}: permissions.allow server 'demo' undefined in mcpServers",
    ]


def test_allowed_server_not_enabled_must_exist(tmp_path: pathlib.Path) -> None:
    settings = valid_settings()
    empty: list[str] = []
    settings["enabledMcpjsonServers"] = empty
    paths = write_configs(tmp_path, settings, {"mcpServers": {}})
    assert checker.check(*paths) == [
        f"{paths[0]}: permissions.allow server 'demo' undefined in mcpServers"
    ]


def test_allow_entries_after_other_tools_are_still_checked(
    tmp_path: pathlib.Path,
) -> None:
    settings = valid_settings()
    settings["permissions"] = {"deny": DENIED, "allow": ["Bash(ls:*)", "mcp__ghost"]}
    empty: list[str] = []
    settings["enabledMcpjsonServers"] = empty
    paths = write_configs(tmp_path, settings, {"mcpServers": {}})
    assert checker.check(*paths) == [
        f"{paths[0]}: permissions.allow server 'ghost' undefined in mcpServers"
    ]


@pytest.mark.parametrize("entry", ["mcp__", "mcp__demo__tool", "mcp__demo__*"])
def test_allow_requires_exact_server_form(tmp_path: pathlib.Path, entry: str) -> None:
    settings = valid_settings()
    settings["permissions"] = {"deny": DENIED, "allow": ["mcp__demo", entry]}
    paths = write_configs(tmp_path, settings, {"mcpServers": {"demo": {}}})
    assert checker.check(*paths) == [
        (
            f"{paths[0]}: permissions.allow entry {entry!r} "
            "must be mcp__<server> with no tool suffix"
        )
    ]


@pytest.mark.parametrize("value", [None, False, 1, "text", []])
@pytest.mark.parametrize("document", ["settings", "mcp"])
def test_json_root_must_be_object(
    tmp_path: pathlib.Path, value: object, document: str
) -> None:
    settings: object = valid_settings()
    mcp: object = {"mcpServers": {"demo": {}}}
    if document == "settings":
        settings = value
    else:
        mcp = value
    paths = write_configs(tmp_path, settings, mcp)
    path = paths[0] if document == "settings" else paths[1]
    assert f"{path}: JSON root must be an object (missing or wrongly typed)" in (
        checker.check(*paths)
    )


@pytest.mark.parametrize("value", [None, False, 1, "text", []])
@pytest.mark.parametrize("key", ["permissions", "mcpServers"])
def test_object_keys_are_required_and_typed(
    tmp_path: pathlib.Path, value: object, key: str
) -> None:
    settings = valid_settings()
    mcp: dict[str, object] = {"mcpServers": {"demo": {}}}
    target = settings if key == "permissions" else mcp
    target[key] = value
    paths = write_configs(tmp_path, settings, mcp)
    path = paths[0] if key == "permissions" else paths[1]
    assert f"{path}: {key} must be an object (missing or wrongly typed)" in (
        checker.check(*paths)
    )
    del target[key]
    assert f"{path}: {key} must be an object (missing or wrongly typed)" in (
        checker.check(*write_configs(tmp_path, settings, mcp))
    )


@pytest.mark.parametrize("value", [None, False, 1, "demo", {}])
@pytest.mark.parametrize("key", ["deny", "allow", "enabledMcpjsonServers"])
def test_list_keys_are_required_and_typed(
    tmp_path: pathlib.Path, value: object, key: str
) -> None:
    settings = valid_settings()
    permissions: dict[str, object] = {"deny": DENIED, "allow": ["mcp__demo"]}
    settings["permissions"] = permissions
    target = settings if key == "enabledMcpjsonServers" else permissions
    target[key] = value
    label = key if key == "enabledMcpjsonServers" else "permissions." + key
    paths = write_configs(tmp_path, settings, {"mcpServers": {"demo": {}}})
    message = (
        f"{paths[0]}: {label} must be a list of strings (missing or wrongly typed)"
    )
    assert message in checker.check(*paths)
    del target[key]
    assert message in checker.check(
        *write_configs(tmp_path, settings, {"mcpServers": {"demo": {}}})
    )


@pytest.mark.parametrize(
    "key", ["permissions.deny", "permissions.allow", "enabledMcpjsonServers"]
)
def test_list_items_must_be_strings(tmp_path: pathlib.Path, key: str) -> None:
    errors: list[str] = []
    assert checker.string_list(
        ["demo", None, 1, {}, [], True], tmp_path, key, errors
    ) == ["demo"]
    assert errors == [
        f"{tmp_path}: {key}[{index}] must be a string" for index in range(1, 6)
    ]


@pytest.mark.parametrize("index", [0, 1])
@pytest.mark.parametrize("content", [b"{\ninvalid\n}", b"\xff"])
def test_invalid_json_and_encoding(
    tmp_path: pathlib.Path, index: int, content: bytes
) -> None:
    paths = write_configs(tmp_path, valid_settings(), {"mcpServers": {"demo": {}}})
    paths[index].write_bytes(content)
    with pytest.raises(ValueError, match=r"\S") as raised:
        json.loads(content)
    expected = f"{paths[index]}: cannot read JSON: {str(raised.value)!r}"
    errors = checker.check(*paths)
    assert errors[0] == expected
    assert all("\n" not in error for error in errors)


def read_failure(path: pathlib.Path) -> str:
    with pytest.raises(OSError, match=re.escape(str(path))) as caught:
        path.read_bytes()
    return f"{path}: cannot read JSON: {str(caught.value)!r}"


@pytest.mark.parametrize("index", [0, 1])
def test_missing_files_and_directories(tmp_path: pathlib.Path, index: int) -> None:
    paths = write_configs(tmp_path, valid_settings(), {"mcpServers": {"demo": {}}})
    paths[index].unlink()
    assert checker.check(*paths)[0] == read_failure(paths[index])
    paths[index].mkdir()
    assert checker.check(*paths)[0] == read_failure(paths[index])


def test_main_success_and_argv(
    tmp_path: pathlib.Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    paths = write_configs(tmp_path, valid_settings(), {"mcpServers": {"demo": {}}})
    monkeypatch.setattr(sys, "argv", ["check_claude_settings.py", *map(str, paths)])
    assert checker.main() == 0
    assert capsys.readouterr().out == ""


def test_main_reports_one_line_per_problem(
    tmp_path: pathlib.Path, capsys: pytest.CaptureFixture[str]
) -> None:
    settings = valid_settings()
    settings["enabledMcpjsonServers"] = ["missing\nserver"]
    paths = write_configs(tmp_path, settings, {"mcpServers": {"demo": {}}})
    assert checker.main(list(map(str, paths))) == 1
    assert capsys.readouterr().out.splitlines() == checker.check(*paths)


@pytest.mark.parametrize("argv", [[], ["settings.json"], ["one", "two", "three"]])
def test_main_requires_two_paths(argv: list[str]) -> None:
    with pytest.raises(SystemExit) as caught:
        checker.main(argv)
    assert caught.value.code == 2
