# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import tomllib
from typing import TYPE_CHECKING
from unittest.mock import Mock

import pytest

from lint.private import check_module_size as module_size

if TYPE_CHECKING:
    from pathlib import Path


@pytest.mark.parametrize(
    ("count", "allowed", "expected"),
    [
        (501, None, "501 lines, over limit 500. Split or shorten the file."),
        (500, None, None),
        (603, 602, "603 lines, over baseline 602. Split or shorten the file."),
        (602, 602, None),
        (601, 602, "601 lines, below baseline 602. Lower the entry to 601."),
        (500, 602, "500 lines, within limit 500. Remove baseline entry (602)."),
        (None, 602, "no counted file for baseline 602. Remove the entry."),
    ],
)
def test_violations(
    count: int | None, allowed: int | None, expected: str | None
) -> None:
    files = {} if count is None else {"a.py": (count, 500)}
    baseline = {} if allowed is None else {"a.py": allowed}
    assert module_size.violations(files, baseline) == (
        [f"a.py: {expected}"] if expected else []
    )


def test_measure(tmp_path: Path) -> None:
    fixtures = {
        "main.py": b"first\r\n\r\nlast",
        "test_main.py": b"",
        "pkg/tests/main.js": b"line\n",
        "pkg/FooTests.swift": b"line\r\n",
        "pkg/main.spec.ts": b"line",
        "node_modules/pkg/main.ts": b"line\n",
        "pkg/generated/main.py": b"line\n",
        "nested/.bazel-out/main.sh": b"line\n",
        "vendor/main.go": b"line\n",
        "main.pb.go": b"line\n",
        "main_pb2.py": b"line\n",
        "README.md": b"line\n",
    }
    for name, contents in fixtures.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
    assert module_size.measure(
        tmp_path, [*fixtures, "missing.py"], module_size.Settings()
    ) == {
        "main.py": (3, 500),
        "test_main.py": (0, 1000),
        "pkg/tests/main.js": (1, 1000),
        "pkg/FooTests.swift": (1, 1000),
        "pkg/main.spec.ts": (1, 1000),
    }


@pytest.mark.parametrize(
    ("data", "diagnostic"),
    [
        ("unknown = 1", "unknown configuration keys"),
        ("baseline = []", "baseline must be a TOML table"),
        ("source_limit = true", "source_limit must be a nonnegative integer"),
        ("test_limit = -1", "test_limit must be a nonnegative integer"),
        ("ignore_globs = true", "ignore_globs must be an array"),
        ('test_globs = [""]', "test_globs must be an array"),
        (
            '[baseline]\n"a.py" = 0.5',
            "baseline entry 'a.py' must be a nonnegative integer",
        ),
    ],
)
def test_invalid_settings(tmp_path: Path, data: str, diagnostic: str) -> None:
    config = tmp_path / "config.toml"
    config.write_text(data, encoding="utf-8")
    with pytest.raises((TypeError, ValueError), match=diagnostic):
        module_size.read_settings(config)


def test_commands(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    for path in ("app.custom", "check.custom", "other.py", "omit.custom"):
        (tmp_path / path).write_bytes(b"one\ntwo\n")
    git = Mock(return_value=b"other.py\0check.custom\0omit.custom\0app.custom\0")
    monkeypatch.setattr(module_size.subprocess, "check_output", git)
    assert module_size.main([]) == 0
    git.assert_called_once_with(
        ["git", "ls-files", "--cached", "--deduplicate", "-z"], cwd=tmp_path
    )

    (tmp_path / "config.toml").write_text(
        'source_limit = 1\ntest_limit = 2\nsource_globs = ["**/*.custom"]\n'
        'test_globs = ["check.custom"]\nignore_globs = ["omit.custom"]\n[baseline]\n',
        encoding="utf-8",
    )
    args = ["--config", "config.toml"]
    assert module_size.main(args) == 1
    assert (
        capsys.readouterr().err
        == "app.custom: 2 lines, over limit 1. Split or shorten the file.\n"
    )
    assert module_size.main([*args, "--write-baseline"]) == 0
    assert tomllib.loads(capsys.readouterr().out) == {"baseline": {"app.custom": 2}}
    assert module_size.main(["--config", "missing.toml"]) == 2
    assert "missing.toml" in capsys.readouterr().err


def test_baseline_toml() -> None:
    path = 'a/"é\x7f".py'
    assert tomllib.loads(module_size.baseline_toml({path: (501, 500)})) == {
        "baseline": {path: 501},
    }
