# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from private import ansible_check

if TYPE_CHECKING:
    from collections.abc import Mapping, Sequence

type Call = tuple[list[str], dict[str, str], Path | None]


@pytest.fixture
def calls(monkeypatch: pytest.MonkeyPatch) -> list[Call]:
    """Record each tool command instead of running it.

    A command fails when its last argument names `bad`.
    """
    recorded: list[Call] = []

    class Done:
        def __init__(self, returncode: int) -> None:
            self.returncode = returncode

    def fake_run(
        command: Sequence[str], *, env: Mapping[str, str], cwd: Path | None, check: bool
    ) -> Done:
        assert not check
        recorded.append((list(command), dict(env), cwd))
        return Done(1 if "bad" in command[-1] else 0)

    monkeypatch.setattr(ansible_check.subprocess, "run", fake_run)
    return recorded


def test_environment_uses_the_tree_config_and_pinned_collections(
    tmp_path: Path,
) -> None:
    root, tmp = tmp_path / "tree", tmp_path / "tmp"
    root.mkdir()
    tmp.mkdir()
    (root / "ansible.cfg").write_text("[defaults]\n")
    env = ansible_check.environment(
        root, tmp, {"TBHB_ANSIBLE_COLLECTIONS": "/a::/b", "KEEP": "1"}
    )
    assert env["KEEP"] == "1"
    assert env["ANSIBLE_CONFIG"] == str(root / "ansible.cfg")
    assert env["ANSIBLE_COLLECTIONS_PATH"] == "/a:/b"
    assert env["ANSIBLE_COLLECTIONS_SCAN_SYS_PATH"] == "false"
    for key in ("ANSIBLE_HOME", "ANSIBLE_LOCAL_TEMP", "ANSIBLE_REMOTE_TEMP"):
        assert Path(env[key]).parent == tmp
    assert env["ANSIBLE_INVENTORY_UNPARSED_FAILED"] == "true"
    assert env["ANSIBLE_INVENTORY_ANY_UNPARSED_IS_FAILED"] == "true"


def test_environment_without_config_or_collections_stays_inside_tmp(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    env = ansible_check.environment(tmp_path / "tree", tmp_path, {})
    assert env["ANSIBLE_CONFIG"] == str(tmp_path / "ansible.cfg")
    assert (tmp_path / "ansible.cfg").read_text() == ""
    assert env["ANSIBLE_COLLECTIONS_PATH"] == str(tmp_path / "collections")
    assert (tmp_path / "collections").is_dir()
    assert "using an empty one" in capsys.readouterr().out


def test_syntax_lists_the_inventory_then_checks_each_playbook(
    calls: list[Call], capsys: pytest.CaptureFixture[str]
) -> None:
    assert ansible_check.syntax("hosts.yml", ["a.yml", "b.yml"], {}) == 0
    assert [c[0] for c in calls] == [
        ["ansible-inventory", "--list", "-i", "hosts.yml"],
        ["ansible-playbook", "--syntax-check", "-i", "hosts.yml", "a.yml"],
        ["ansible-playbook", "--syntax-check", "-i", "hosts.yml", "b.yml"],
    ]
    assert "inventory and 2 playbook(s) passed" in capsys.readouterr().out


def test_syntax_reports_every_failure(
    calls: list[Call], capsys: pytest.CaptureFixture[str]
) -> None:
    assert ansible_check.syntax("bad.ini", ["ok.yml", "bad.yml"], {}) == 1
    assert len(calls) == 3
    assert "FAIL: inventory bad.ini, playbook bad.yml" in capsys.readouterr().err


def test_lint_config_prefers_the_checks_config(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / ".ansible-lint").write_text("")
    assert (
        ansible_check.lint_config(tmp_path, "cfg/lint.yml", {})
        == tmp_path / "cfg/lint.yml"
    )
    assert "cfg/lint.yml (the check's `config`)" in capsys.readouterr().out


def test_lint_config_finds_the_trees_own(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / ".config").mkdir()
    (tmp_path / ".config/ansible-lint.yml").write_text("")
    assert (
        ansible_check.lint_config(tmp_path, "", {})
        == tmp_path / ".config/ansible-lint.yml"
    )
    assert ".config/ansible-lint.yml (the tree's own)" in capsys.readouterr().out


def test_lint_config_falls_back_to_the_default(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    default = tmp_path / "default.yml"
    default.write_text("profile: production\n")
    root = tmp_path / "tree"
    root.mkdir()
    config = ansible_check.lint_config(
        root, "", {"TBHB_ANSIBLE_LINT_DEFAULT_CONFIG": str(default)}
    )
    assert config == root / ".ansible-lint"
    assert config.read_text() == "profile: production\n"
    assert "tbhb_rules_ansible's default" in capsys.readouterr().out


@pytest.fixture
def tree(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "tree"
    root.mkdir()
    (root / ".ansible-lint").write_text("")
    tmp = tmp_path / "tmp"
    tmp.mkdir()
    monkeypatch.chdir(root)
    monkeypatch.setenv("TEST_TMPDIR", str(tmp))
    monkeypatch.delenv("TBHB_ANSIBLE_COLLECTIONS", raising=False)
    return root


@pytest.mark.usefixtures("tree")
def test_main_syntax(calls: list[Call]) -> None:
    assert (
        ansible_check.main(
            ["syntax", "--inventory", "hosts.yml", "site.yml", "extra.yml"]
        )
        == 0
    )
    assert calls[-1][0][-1] == "extra.yml"


def test_main_lint_runs_offline_with_the_chosen_config(
    tree: Path, calls: list[Call]
) -> None:
    assert ansible_check.main(["lint", "roles/"]) == 0
    assert calls == [
        (
            [
                "ansible-lint",
                "--offline",
                "--project-dir",
                ".",
                "-c",
                str(tree / ".ansible-lint"),
                "roles/",
            ],
            calls[0][1],
            None,
        )
    ]
    assert calls[0][1]["ANSIBLE_CONFIG"].endswith("ansible.cfg")


def test_main_molecule_runs_from_the_role(tree: Path, calls: list[Call]) -> None:
    assert (
        ansible_check.main(["molecule", "--role", "roles/web", "--scenario", "bad"])
        == 1
    )
    command, env, cwd = calls[0]
    assert command == ["molecule", "test", "-s", "bad"]
    assert cwd == tree / "roles/web"
    assert env["MOLECULE_EPHEMERAL_DIRECTORY"] == str(
        Path(env["TEST_TMPDIR"]) / "molecule"
    )
