# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import re
import shlex
import shutil
import subprocess
import tomllib
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).absolute().parents[2]
BASELINE = ROOT / "repo/baseline"
SOURCE = "files/.github/gitleaks-hook.sh"
ROOT_CONFIG = ROOT / ".pre-commit-config.yaml"
CONFIGS = [ROOT_CONFIG, *sorted((BASELINE / "seed").glob("*/pre-commit-config.yaml"))]
STUB = r"""#!/bin/sh
if [ "$1" = version ]; then
  printf '%s' "$VERSION_OUTPUT"
  exit "$VERSION_STATUS"
fi
printf '%s\n' "$0" "$@"
for config do :; done
cat -- "$config" > "$CAPTURE_CONFIG" || exit 2
if [ "$1" = stdin ]; then
  IFS= read -r message
  printf '%s\n' "$message"
fi
exit 37
"""


@pytest.fixture
def pinned_version() -> str:
    pins = (ROOT / "pins/extensions.bzl").read_text()
    versions: set[str] = set(
        re.findall(r"/gitleaks/releases/download/v([^/]+)/gitleaks_", pins)
    )
    assert len(versions) == 1, versions
    return versions.pop()


def test_hook_pin(pinned_version: str) -> None:
    script = (BASELINE / SOURCE).read_text()
    assert re.findall(r"^expected_version=(\S+)$", script, re.MULTILINE) == [
        pinned_version
    ]


def _prepare_checkout(tmp_path: Path, config: Path) -> Path:
    source = BASELINE / SOURCE
    if config == ROOT_CONFIG:
        script = source.relative_to(ROOT)
        shim = Path("tools/.bazel_env/bin/gitleaks")
        policy = ROOT / ".gitleaks.toml"
    else:
        manifest = tomllib.loads((BASELINE / "manifest.toml").read_text())
        (entry,) = (entry for entry in manifest["file"] if entry["source"] == SOURCE)
        assert entry["mode"] == "bytes"
        assert entry["visibility"] == "all"
        assert "kinds" not in entry
        script = Path(entry["path"])
        shim = Path(".bazel_env/bin/gitleaks")
        policy = BASELINE / "files/.gitleaks.toml"
    (tmp_path / script).parent.mkdir(parents=True)
    shutil.copyfile(source, tmp_path / script)
    shutil.copyfile(policy, tmp_path / policy.name)

    path = tmp_path / "bin"
    path.mkdir()
    for command in ("bash", "cat", "mktemp", "rm"):
        located = shutil.which(command)
        assert located is not None, command
        (path / command).symlink_to(located)
    return shim


@pytest.mark.parametrize(
    "config", CONFIGS, ids=["root", *(p.parent.name for p in CONFIGS[1:])]
)
@pytest.mark.parametrize(
    "case",
    [
        pytest.param((0o755, "{pin}\n", 0, None), id="shim-first"),
        pytest.param((None, "{pin}\n", 0, None), id="path"),
        pytest.param((0o644, "{pin}\n", 0, None), id="shim-not-executable"),
        pytest.param((None, "0.0.0\n", 0, "found version 0.0.0"), id="wrong-version"),
        pytest.param((None, "{pin}\n\n", 0, "found version"), id="extra-output"),
        pytest.param((None, "{pin}\n", 3, "version command failed"), id="failed-probe"),
        pytest.param((None, None, 0, "absent from PATH"), id="missing"),
    ],
)
def test_hook(
    tmp_path: Path,
    config: Path,
    case: tuple[int | None, str | None, int, str | None],
    pinned_version: str,
) -> None:
    shim_mode, version_output, version_status, failure = case
    shim = _prepare_checkout(tmp_path, config)
    path = tmp_path / "bin"
    path_binary = path / "gitleaks"
    if version_output is not None:
        path_binary.write_text(STUB)
        path_binary.chmod(0o755)
    if shim_mode is not None:
        (tmp_path / shim).parent.mkdir(parents=True)
        (tmp_path / shim).write_text(STUB)
        (tmp_path / shim).chmod(shim_mode)

    message = tmp_path / "commit message.txt"
    message.write_text("test commit message\n")
    hooks = {
        hook["id"]: hook
        for repo in yaml.safe_load(config.read_text())["repos"]
        for hook in repo["hooks"]
    }
    common = ["--redact", "--no-banner", "--config"]
    invocations: list[tuple[str, list[str], list[str], list[str]]] = [
        ("gitleaks", [], ["git", "--pre-commit", "--staged", *common], []),
        (
            "gitleaks-commit-msg",
            [message.name],
            ["stdin", *common],
            ["test commit message"],
        ),
    ]
    for hook_id, extra, scan_args, scanned_input in invocations:
        hook = hooks[hook_id]
        assert hook["always_run"]
        captured_config = tmp_path / f"{hook_id}.toml"
        result = subprocess.run(
            [*shlex.split(hook["entry"]), *extra],
            cwd=tmp_path,
            env={
                "CAPTURE_CONFIG": str(captured_config),
                "PATH": str(path),
                "TMPDIR": str(tmp_path),
                "VERSION_OUTPUT": (version_output or "").format(pin=pinned_version),
                "VERSION_STATUS": str(version_status),
            },
            capture_output=True,
            text=True,
            check=False,
        )
        if failure:
            assert result.returncode == 1, result
            assert not result.stdout
            assert str(shim) in result.stderr
            assert f"gitleaks {pinned_version} on PATH" in result.stderr
            assert failure in result.stderr
            continue

        binary = shim if shim_mode == 0o755 else path_binary
        assert result.returncode == 37, result
        assert not result.stderr
        launched, *output = result.stdout.splitlines()
        assert (tmp_path / launched).resolve() == (tmp_path / binary).resolve()
        config_arg = output[len(scan_args)]
        assert output == [*scan_args, config_arg, *scanned_input]
        expected_config = tomllib.loads((tmp_path / ".gitleaks.toml").read_text())
        if config == ROOT_CONFIG and binary == path_binary:
            assert Path(config_arg).parent == tmp_path
            assert not Path(config_arg).exists()
            expected_config["extend"] = {"path": "lint/gitleaks/base.toml"}
        else:
            assert config_arg == ".gitleaks.toml"
        assert tomllib.loads(captured_config.read_text()) == expected_config
