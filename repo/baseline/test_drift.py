# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import itertools
from typing import TYPE_CHECKING, cast

import pytest

from repo.baseline.baseline_drift import (
    BASELINE,
    Manifest,
    load_declaration,
    load_toml,
    main,
    selected_entries,
)

if TYPE_CHECKING:
    from pathlib import Path

MCP = ".mcp.json"
RENOVATE = ".github/workflows/renovate.yaml"
RENOVATE_VALIDATOR = ".github/workflows/renovate-config-validator.yaml"
PINS = {
    RENOVATE: b"0123456789abcdef0123456789abcdef01234567",
    RENOVATE_VALIDATOR: b"FEDCBA9876543210FEDCBA9876543210FEDCBA98",
}
PIN_NEEDED = "(template values needed for renovate_config_sha)"
MCP_VALUES = {
    b"{{mcp_server}}": b"fixture",
    b"{{mcp_module}}": b"example.org/fixture@v0.0.1",
    b"{{mcp_endpoint_env}}": b"FIXTURE_ENDPOINT",
    b"{{mcp_endpoint}}": b"wss://example.org/mcp",
    b"{{mcp_token_file_env}}": b"FIXTURE_TOKEN_FILE",
    b"{{mcp_token_file}}": r"${HOME}/file \"é\"\\token".encode(),
}


def declare(repo: Path, kind: str = "go", *, private: bool = False) -> None:
    (repo / ".tbhb-repo.toml").write_text(
        f'schema_version = 1\nkind = "{kind}"\nprivate = {str(private).lower()}\n',
        encoding="utf-8",
    )


def add_exception(repo: Path, path: str, reason: str, *, check: str = "C2") -> None:
    with (repo / ".tbhb-repo.toml").open("a", encoding="utf-8") as stream:
        stream.write(f'\n[[exception]]\ncheck = "{check}"\npath = "{path}"\n{reason}\n')


def check(repo: Path, mode: str = "required") -> int:
    return main(["check", str(repo), "--mode", mode])


def copy_baseline(repo: Path) -> None:
    manifest = cast("Manifest", load_toml(BASELINE / "manifest.toml"))
    for entry in selected_entries(manifest, load_declaration(repo, BASELINE)):
        path = entry["path"]
        content = (BASELINE / entry["source"]).read_bytes()
        if path in PINS:
            content = content.replace(b"{{renovate_config_sha}}", PINS[path])
        elif path == MCP:
            for token, value in MCP_VALUES.items():
                content = content.replace(token, value)
        destination = repo / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)


@pytest.fixture
def consumer(tmp_path: Path) -> Path:
    declare(tmp_path)
    copy_baseline(tmp_path)
    return tmp_path


@pytest.mark.parametrize(
    ("kind", "private"),
    list(itertools.product(["go", "python", "docs", "chezmoi"], [True, False])),
)
def test_selection_and_identical(
    tmp_path: Path, kind: str, private: bool, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(tmp_path, kind, private=private)
    copy_baseline(tmp_path)
    assert (tmp_path / "LICENSE").is_file() is not private
    assert (tmp_path / "LICENSES/LicenseRef-Proprietary.txt").is_file() is private
    assert (tmp_path / "size-check.sh").is_file() == (private or kind != "go")
    assert (tmp_path / ".python-version").is_file() == (kind != "go")
    assert not (tmp_path / ".editorconfig").exists()
    assert not (tmp_path / "mise.toml").exists()
    assert not (tmp_path / "BUILD.bazel").exists()
    assert check(tmp_path) == 0
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize(
    ("mode", "level", "status"),
    [
        ("warn", "warning", 0),
        ("required", "error", 1),
    ],
)
def test_missing_and_drifted(
    consumer: Path,
    mode: str,
    level: str,
    status: int,
    capsys: pytest.CaptureFixture[str],
) -> None:
    version = consumer / ".bazelversion"
    version.write_bytes(version.read_bytes().replace(b"\n", b"\r\n"))
    (consumer / ".github/actionlint.yaml").unlink()
    assert check(consumer, mode) == status
    assert capsys.readouterr().out.splitlines() == [
        f"C2 {level}: .bazelversion differs",
        f"C2 {level}: .github/actionlint.yaml missing",
    ]


def test_exceptions(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    (consumer / "LICENSE").write_text("Repository license", encoding="utf-8")
    (consumer / ".bazelversion").unlink()
    (consumer / MCP).write_bytes(b"{}")
    add_exception(
        consumer, "LICENSE", 'reason = "The repository uses its own license."'
    )
    add_exception(consumer, ".bazelversion", 'reason = "Version rollout is pending."')
    add_exception(consumer, MCP, 'reason = "This repository uses another MCP setup."')
    add_exception(
        consumer, ".github/actionlint.yaml", 'reason = "Another check."', check="C4"
    )
    assert check(consumer) == 0
    assert capsys.readouterr().out.splitlines() == [
        "C2 exception for LICENSE: The repository uses its own license.",
        "C2 exception for .bazelversion: Version rollout is pending.",
        f"C2 exception for {MCP}: This repository uses another MCP setup.",
    ]
    assert not (consumer / ".bazelversion").exists()
    assert (consumer / "LICENSE").read_text(encoding="utf-8") == "Repository license"


@pytest.mark.parametrize("reason", ["", 'reason = "  "', "reason = false"])
def test_invalid_reason(
    consumer: Path, reason: str, capsys: pytest.CaptureFixture[str]
) -> None:
    (consumer / "LICENSE").unlink()
    add_exception(consumer, "LICENSE", reason)
    assert check(consumer, "warn") == 1
    assert "C2 error: .tbhb-repo.toml:" in capsys.readouterr().err
    assert not (consumer / "LICENSE").exists()


@pytest.mark.parametrize("path", ["LICENSE", "size-check.sh", "README.md", MCP])
def test_stale_exception(
    consumer: Path, path: str, capsys: pytest.CaptureFixture[str]
) -> None:
    add_exception(consumer, path, 'reason = "Earlier divergence."')
    assert check(consumer, "warn") == 1
    assert f"stale C2 exceptions for {path}" in capsys.readouterr().err


def test_template_drift(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    mcp = consumer / MCP
    mcp.write_bytes(mcp.read_bytes().replace(b'"go"', b'"other"'))
    renovate = consumer / RENOVATE
    renovate.write_bytes(
        renovate.read_bytes().replace(b"github.event_name", b"github.event")
    )
    validator = consumer / RENOVATE_VALIDATOR
    validator.write_bytes(validator.read_bytes() + b"\n")
    assert check(consumer) == 1
    assert capsys.readouterr().out.splitlines() == [
        f"C2 error: {MCP} differs",
        f"C2 error: {RENOVATE} differs",
        f"C2 error: {RENOVATE_VALIDATOR} differs",
    ]


@pytest.mark.parametrize(
    "content",
    [
        b"invalid",
        b"\xff",
        b'{"mcpServers":{"first":{},"second":{}}}',
        b'{"mcpServers":{"fixture":{"args":["mcp"],"env":{}}}}',
        b'{"mcpServers":{"fixture":{"args":["run","module","mcp"],"env":{"KEY":1}}}}',
    ],
)
def test_unrecoverable_mcp(
    consumer: Path, content: bytes, capsys: pytest.CaptureFixture[str]
) -> None:
    (consumer / MCP).write_bytes(content)
    assert check(consumer, "warn") == 0
    assert (
        f"C2 warning: {MCP} differs (template values needed" in capsys.readouterr().out
    )


def test_missing_workflow(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    (consumer / RENOVATE).unlink()
    assert check(consumer) == 1
    assert capsys.readouterr().out.splitlines() == [
        f"C2 error: {RENOVATE} missing {PIN_NEEDED}",
    ]


@pytest.mark.parametrize("pin", [b"main", b"0" * 41])
def test_invalid_renovate_pin(
    consumer: Path, pin: bytes, capsys: pytest.CaptureFixture[str]
) -> None:
    renovate = consumer / RENOVATE
    renovate.write_bytes(renovate.read_bytes().replace(PINS[RENOVATE], pin))
    assert check(consumer) == 1
    assert capsys.readouterr().out.splitlines() == [
        f"C2 error: {RENOVATE} differs {PIN_NEEDED}",
    ]


def test_ambiguous_renovate_pin(
    consumer: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    renovate = consumer / RENOVATE
    content = renovate.read_bytes()
    [uses] = [line for line in content.splitlines() if PINS[RENOVATE] in line]
    renovate.write_bytes(
        content + uses.replace(PINS[RENOVATE], PINS[RENOVATE_VALIDATOR]) + b"\n"
    )
    assert check(consumer) == 1
    assert capsys.readouterr().out.splitlines() == [
        f"C2 error: {RENOVATE} differs {PIN_NEEDED}",
    ]


def test_duplicate_exception(
    consumer: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (consumer / "LICENSE").unlink()
    add_exception(consumer, "LICENSE", 'reason = "Reason one."')
    add_exception(consumer, "LICENSE", 'reason = "Reason two."')
    assert check(consumer) == 1
    assert "duplicate C2 exception for LICENSE" in capsys.readouterr().err


def test_invalid_declaration(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert check(tmp_path, "warn") == 1
    assert ".tbhb-repo.toml" in capsys.readouterr().err
    (tmp_path / ".tbhb-repo.toml").write_bytes(b"invalid")
    assert check(tmp_path, "warn") == 1
    assert ".tbhb-repo.toml" in capsys.readouterr().err


def test_invalid_baseline(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["check", str(tmp_path), "--mode", "warn"], baseline=tmp_path) == 2
    assert "manifest.toml" in capsys.readouterr().err


def test_unreadable_file(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    target = consumer / ".bazelversion"
    target.unlink()
    target.mkdir()
    assert check(consumer, "warn") == 2
    assert "C2 error:" in capsys.readouterr().err
