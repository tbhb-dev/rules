# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import itertools
import json
import shutil
from pathlib import Path

import pytest

from repo.baseline.baseline_drift import BASELINE, main

PIN = "0123456789abcdef0123456789abcdef01234567"
FIXTURE_PATH = '${HOME}/file "with quotes"'
VALUE_ARGS = [
    "--value",
    "renovate_config_sha",
    PIN,
    "--value",
    "mcp_server",
    "fixture",
    "--value",
    "mcp_module",
    "example.org/fixture@v0.0.1",
    "--value",
    "mcp_endpoint_env",
    "FIXTURE_ENDPOINT",
    "--value",
    "mcp_endpoint",
    "wss://example.org/mcp",
    "--value",
    "mcp_token_file_env",
    "FIXTURE_TOKEN_FILE",
    "--value",
    "mcp_token_file",
    FIXTURE_PATH,
]


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


def sync(repo: Path, *args: str, baseline: Path = BASELINE) -> int:
    return main(["sync", str(repo), *args], baseline=baseline)


@pytest.fixture
def consumer(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> Path:
    declare(tmp_path)
    assert sync(tmp_path, *VALUE_ARGS) == 0
    capsys.readouterr()
    return tmp_path


@pytest.mark.parametrize(
    ("kind", "private"),
    list(itertools.product(["go", "python", "docs", "chezmoi"], [True, False])),
)
def test_selection_and_identical(
    tmp_path: Path, kind: str, private: bool, capsys: pytest.CaptureFixture[str]
) -> None:
    declare(tmp_path, kind, private=private)
    assert sync(tmp_path, *VALUE_ARGS) == 0
    assert "create .bazelversion" in capsys.readouterr().out
    assert (tmp_path / "LICENSE").is_file() is not private
    assert (tmp_path / "LICENSES/LicenseRef-Proprietary.txt").is_file() is private
    assert (tmp_path / "size-check.sh").is_file() == (private or kind != "go")
    assert (tmp_path / ".python-version").is_file() == (kind != "go")
    assert not (tmp_path / ".editorconfig").exists()
    assert not (tmp_path / "mise.toml").exists()
    assert not (tmp_path / "BUILD.bazel").exists()
    assert check(tmp_path) == 0
    assert sync(tmp_path) == 0
    assert not capsys.readouterr().out


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
    add_exception(
        consumer, "LICENSE", 'reason = "The repository uses its own license."'
    )
    add_exception(consumer, ".bazelversion", 'reason = "Version rollout is pending."')
    add_exception(
        consumer, ".github/actionlint.yaml", 'reason = "Another check."', check="C4"
    )
    for result in (check(consumer), sync(consumer)):
        assert result == 0
    diagnostics = [
        "C2 exception for LICENSE: The repository uses its own license.",
        "C2 exception for .bazelversion: Version rollout is pending.",
    ]
    assert capsys.readouterr().out.splitlines() == diagnostics * 2
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
    assert sync(consumer) == 1
    assert not (consumer / "LICENSE").exists()


@pytest.mark.parametrize("path", ["LICENSE", "size-check.sh", "README.md"])
def test_stale_exception(
    consumer: Path, path: str, capsys: pytest.CaptureFixture[str]
) -> None:
    add_exception(consumer, path, 'reason = "Earlier divergence."')
    assert check(consumer, "warn") == 1
    assert f"stale C2 exceptions for {path}" in capsys.readouterr().err


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


def test_dry_run_and_sync(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    version = consumer / ".bazelversion"
    version.write_bytes(b"old\n")
    version.chmod(0o755)
    original_mode = version.stat().st_mode
    missing = consumer / ".github/actionlint.yaml"
    missing.unlink()
    assert sync(consumer, "--dry-run") == 0
    assert capsys.readouterr().out.splitlines() == [
        "Would update .bazelversion",
        "Would create .github/actionlint.yaml",
    ]
    assert version.read_bytes() == b"old\n"
    assert not missing.exists()
    assert sync(consumer) == 0
    assert capsys.readouterr().out.splitlines() == [
        "update .bazelversion",
        "create .github/actionlint.yaml",
    ]
    assert version.stat().st_mode == original_mode
    assert check(consumer) == 0


def test_sync_preserves_template_values(
    consumer: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    workflow = consumer / ".github/workflows/renovate.yaml"
    mcp = consumer / ".mcp.json"
    expected = mcp.read_bytes()
    assert (
        json.loads(expected)["mcpServers"]["fixture"]["env"]["FIXTURE_TOKEN_FILE"]
        == FIXTURE_PATH
    )
    mcp.write_bytes(expected + b"\n")
    workflow.write_bytes(
        workflow.read_bytes().replace(b"name: Renovate", b"name: Changed")
    )
    assert check(consumer) == 1
    assert capsys.readouterr().out.splitlines() == [
        "C2 error: .mcp.json differs",
        "C2 error: .github/workflows/renovate.yaml differs",
    ]
    assert sync(consumer) == 0
    assert mcp.read_bytes() == expected
    assert PIN.encode() in workflow.read_bytes()
    assert b"${{ github.event_name" in workflow.read_bytes()
    assert check(consumer) == 0


@pytest.mark.parametrize(
    "content",
    [
        b"invalid",
        b"{}",
        b'{"mcpServers":{"fixture":{}}}',
        b'{"mcpServers":{"fixture":{"args":["run","module","mcp"],"env":{}}}}',
    ],
)
def test_unrecoverable_mcp(
    consumer: Path, content: bytes, capsys: pytest.CaptureFixture[str]
) -> None:
    (consumer / ".mcp.json").write_bytes(content)
    assert check(consumer, "warn") == 0
    assert ".mcp.json differs (template values needed" in capsys.readouterr().out
    earlier = consumer / ".bazelversion"
    earlier.write_bytes(b"drift\n")
    assert sync(consumer) == 2
    assert "template values needed" in capsys.readouterr().err
    assert earlier.read_bytes() == b"drift\n"
    assert sync(consumer, *VALUE_ARGS) == 0
    assert check(consumer) == 0


def test_missing_workflow(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    workflow = consumer / ".github/workflows/renovate.yaml"
    workflow.unlink()
    assert check(consumer) == 1
    assert "renovate.yaml missing (template values needed" in capsys.readouterr().out
    assert sync(consumer, "--value", "renovate_config_sha", "main") == 2
    assert "needs a 40-digit hexadecimal commit" in capsys.readouterr().err
    assert sync(consumer, "--value", "renovate_config_sha", PIN) == 0
    assert check(consumer) == 0


def test_invalid_sync_value(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert sync(consumer, "--value", "unknown", "input") == 2
    assert "unknown baseline template value" in capsys.readouterr().err


def test_invalid_baseline(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert sync(consumer, baseline=consumer / "absent") == 2
    assert "manifest.toml" in capsys.readouterr().err


def test_protected_path(consumer: Path, capsys: pytest.CaptureFixture[str]) -> None:
    baseline = consumer / "baseline"
    shutil.copytree(BASELINE, baseline)
    manifest = baseline / "manifest.toml"
    text = manifest.read_text(encoding="utf-8")
    manifest.write_text(
        text.replace("never_write = [", 'never_write = [".bazel*", '), encoding="utf-8"
    )
    version = consumer / ".bazelversion"
    version.write_bytes(b"local\n")
    assert sync(consumer, baseline=baseline) == 2
    assert ".bazelversion: protected by never_write" in capsys.readouterr().err
    assert version.read_bytes() == b"local\n"


def test_aliased_destination(
    consumer: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    version = consumer / ".bazelversion"
    version.write_bytes(b"local\n")
    resolve = Path.resolve

    def resolve_destination(path: Path) -> Path:
        return consumer / "other-file" if path == version else resolve(path)

    monkeypatch.setattr(Path, "resolve", resolve_destination)
    assert sync(consumer) == 2
    assert (
        "sync needs a regular path inside the consumer root" in capsys.readouterr().err
    )
    assert version.read_bytes() == b"local\n"
