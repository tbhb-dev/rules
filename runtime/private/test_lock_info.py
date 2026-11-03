# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
from typing import TYPE_CHECKING

import pytest

from runtime.private import lock_info

if TYPE_CHECKING:
    from pathlib import Path

SINGLE = """\
version = 1

[[package]]
name = "ascm-workspace"
version = "0"
source = { virtual = "." }

[[package]]
name = "pyyaml"
version = "6.0.3"
source = { registry = "https://pypi.org/simple" }
"""

WORKSPACE = """\
version = 1

[manifest]
members = ["ops-workspace", "tbhbops"]

[[package]]
name = "ops-workspace"
version = "0"
source = { virtual = "." }

[[package]]
name = "tbhbops"
version = "0"
source = { editable = "cli" }

[[package]]
name = "vendored"
version = "1"
source = { editable = "third_party/vendored" }
"""


def test_table_keeps_tables_and_drops_anything_else() -> None:
    assert lock_info.table({"a": 1}) == {"a": 1}
    assert lock_info.table(None) == {}
    assert lock_info.table([1]) == {}


def test_a_single_project_is_its_local_package() -> None:
    lock: dict[str, object] = {
        "package": [
            {"name": "ascm-workspace", "source": {"virtual": "."}},
            {"name": "pyyaml", "source": {"registry": "https://pypi.org/simple"}},
            {"name": "nosource"},
            "not a table",
        ],
    }
    assert lock_info.members(lock) == [
        {"name": "ascm-workspace", "path": ".", "kind": "virtual"},
    ]


def test_a_workspace_lists_only_its_manifest_members() -> None:
    lock: dict[str, object] = {
        "manifest": {"members": ["root", "lib"]},
        "package": [
            {"name": "root", "source": {"virtual": "."}},
            {"name": "other", "source": {"editable": "elsewhere"}},
            {"name": "lib", "source": {"editable": "cli"}},
        ],
    }
    assert lock_info.members(lock) == [
        {"name": "root", "path": ".", "kind": "virtual"},
        {"name": "lib", "path": "cli", "kind": "editable"},
    ]


def test_a_manifest_without_members_falls_back_to_local_packages() -> None:
    constraints: list[str] = []
    lock: dict[str, object] = {
        "manifest": {"constraints": constraints},
        "package": [{"name": "app", "source": {"editable": "."}}],
    }
    assert lock_info.members(lock) == [
        {"name": "app", "path": ".", "kind": "editable"},
    ]


@pytest.mark.parametrize(
    ("lock", "message"),
    [
        ({"package": {"name": "x"}}, "`package` is not an array of tables"),
        ({}, "it records no local project"),
        (
            {"package": [{"name": "x", "source": {"registry": "r"}}]},
            "it records no local project",
        ),
        (
            {
                "manifest": {"members": ["y"]},
                "package": [{"name": "x", "source": {"virtual": "."}}],
            },
            "it records no local project",
        ),
    ],
)
def test_bad_locks_are_rejected(lock: dict[str, object], message: str) -> None:
    with pytest.raises(lock_info.LockError, match=f"^{message}$"):
        lock_info.members(lock)


def test_main_prints_the_members_as_json(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    path = tmp_path / "uv.lock"
    path.write_text(WORKSPACE)
    assert lock_info.main([str(path)]) == 0
    assert json.loads(capsys.readouterr().out) == {
        "members": [
            {"name": "ops-workspace", "path": ".", "kind": "virtual"},
            {"name": "tbhbops", "path": "cli", "kind": "editable"},
        ],
    }
    path.write_text(SINGLE)
    assert lock_info.main([str(path)]) == 0
    assert capsys.readouterr().out == (
        '{"members": [{"name": "ascm-workspace", "path": ".", "kind": "virtual"}]}\n'
    )


def test_main_reports_a_lock_without_a_project(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    path = tmp_path / "uv.lock"
    path.write_text("version = 1\n")
    assert lock_info.main([str(path)]) == 1
    assert capsys.readouterr().err == f"{path}: it records no local project\n"


@pytest.mark.parametrize("argv", [[], ["a", "b"]])
def test_main_needs_exactly_one_lock(
    argv: list[str],
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert lock_info.main(argv) == 2
    assert capsys.readouterr().err == "usage: lock_info.py UV_LOCK\n"
