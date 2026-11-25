# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import subprocess
from pathlib import Path
from unittest.mock import Mock

import pytest
import yaml

from repo.private.tier0_approval import __main__ as gate

HEAD, BASE, REPO = "a" * 40, "b" * 40, "example/wiki"
BOT, WRITER = {"login": "tbhb-dev-auto-reviews[bot]"}, {"login": "writer"}
REF = {"sha": HEAD, "ref": "draft", "repo": {"full_name": REPO}}
PULL = {
    "number": 5,
    "state": "open",
    "draft": False,
    "base": REF | {"sha": BASE, "ref": "main"},
    "head": REF,
    "labels": [{"name": "docs"}],
    "user": WRITER,
}
RUN: gate.Record = {
    "head_sha": HEAD,
    "conclusion": "success",
    "head_branch": "draft",
    "head_repository": REF["repo"],
    "actor": WRITER,
    "triggering_actor": WRITER,
}


def default_paths() -> dict[str, str]:
    workflow = Path(".github/workflows/tier0-approval.yml").read_text(encoding="utf-8")
    # PyYAML's safe loader uses the YAML 1.1 boolean key for "on".
    inputs = yaml.safe_load(workflow)[True]["workflow_call"]["inputs"]
    names = ("tier0_paths", "deny_paths")
    return {name.upper(): inputs[name]["default"] for name in names}


def test_default_paths() -> None:
    env = default_paths()
    for path in ("README.md", "docs/guide/intro.md", "LICENSE"):
        assert gate.tier0_path(path, env), path
    blocked_names = ("AGENTS.override.md", "CLAUDE.local.md", "GEMINI.md", "LICENSE.py")
    for path in (
        *blocked_names,
        "sub/.claude/skills/x/SKILL.md",
        ".agents/skills/x/SKILL.md",
        ".codex/prompts/x.md",
        ".cursor/rules/x.md",
    ):
        assert not gate.tier0_path(path, env), path


def test_contexts(monkeypatch: pytest.MonkeyPatch) -> None:
    success = {"head_sha": HEAD, "conclusion": "success"}
    run = success | {"workflow_id": 123, "check_suite_id": 3}
    check = success | {"name": "CI", "check_suite": {"id": 3}}
    for spec, runs, checks, expected in (
        ("", (), (), False),
        ("CI", (), (), False),
        ("CI:123", (), (), False),
        ("CI:123", [run | {"conclusion": "failure"}], (), False),
        ("CI:123", [run], [check | {"name": "other"}, check], True),
    ):
        api = Mock(side_effect=[{"workflow_runs": runs}, [{"check_runs": checks}]])
        monkeypatch.setattr(gate, "api", api)
        assert gate.contexts_pass(REPO, HEAD, spec) is expected


def test_changed_paths(monkeypatch: pytest.MonkeyPatch) -> None:
    diff = ":100644 000000 777 000 D\0old.md\x000\t1\told.md\0"
    monkeypatch.setattr(gate, "command", Mock(side_effect=["", "", diff]))
    assert gate.changed_paths(REPO, BASE, HEAD) == (["old.md"], True)


def test_decide(monkeypatch: pytest.MonkeyPatch) -> None:
    env = default_paths() | {
        "GITHUB_REPOSITORY": REPO,
        "APP_SLUG": "tbhb-dev-auto-reviews",
        "CHECK_WORKFLOWS": "CI:123",
        "MAX_FILES": "1",
        "DESIGN_PATHS": "docs/design/**",
        "DESIGN_GO_SHA": "",
    }
    commit = {"author": None, "committer": WRITER}
    api = Mock()
    monkeypatch.setattr(gate, "api", api)
    evidence = [
        [[PULL]],
        PULL,
        commit,
        [[{"activity_type": "branch_deletion"}]],
        PULL,
        {"id": 1},
    ]
    for index, value, reason in (
        (0, [[PULL | {"head": REF | {"sha": BASE}}]], "no-unique-open-pr"),
        (1, PULL | {"user": BOT}, "approver-is-author"),
        (1, PULL | {"draft": True}, "not-eligible"),
        (1, PULL | {"state": "closed"}, "pr-changed"),
        (1, PULL | {"labels": [{"name": "no-auto-approval"}]}, "opted-out"),
        (2, commit | {"author": BOT}, "approver-is-committer"),
        (3, [[{"activity_type": "push"}]], "approver-is-pusher"),
    ):
        responses = evidence.copy()
        responses[index] = value
        api.configure_mock(side_effect=responses)
        assert gate.decide(RUN, env)["reason"] == reason
    for paths, regular, checks, mode, reason in (
        (["README.md"], True, True, "enforce", "tier0"),
        (["README.md"], True, True, "evaluate", "tier0"),
        (["README.md"], True, True, "bogus", "invalid-mode"),
        (["docs/design/x.md"], True, True, "evaluate", "design-needs-go"),
        (["a.py"], True, True, "evaluate", "path-outside-tier0"),
        (["README.md"], False, True, "evaluate", "unsupported-file"),
        ((), True, True, "evaluate", "file-count"),
        ((), True, False, "evaluate", "checks-unsuccessful"),
    ):
        api.configure_mock(side_effect=evidence)
        monkeypatch.setattr(gate, "changed_paths", Mock(return_value=(paths, regular)))
        monkeypatch.setattr(gate, "contexts_pass", Mock(return_value=checks))
        assert gate.decide(RUN, env | {"MODE": mode})["reason"] == reason
    for run, app, reason in (
        (RUN | {"head_sha": "bad"}, gate.APP, "invalid-sha"),
        (RUN | {"conclusion": "failure"}, gate.APP, "ci-unsuccessful"),
        (RUN | {"actor": BOT}, gate.APP, "approver-is-pusher"),
        (RUN, "other", "unexpected-approver"),
    ):
        assert gate.decide(run, env | {"APP_SLUG": app})["reason"] == reason


def test_main_and_merge(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_OUTPUT", "output")
    monkeypatch.setenv("GITHUB_EVENT_PATH", "event")
    monkeypatch.setenv("APP_SLUG", "tbhb-dev-auto-reviews")
    Path("event").write_text(json.dumps({"workflow_run": RUN}), encoding="utf-8")
    failure = subprocess.CalledProcessError(1, "gh")
    request = Mock(side_effect=[json.dumps([[PULL]]), failure, "", failure])
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    gate.main()
    artifact = Path("tier0-decision.json")
    assert "evidence-or-command-failed" in artifact.read_text(encoding="utf-8")
    decision = {"pr": 5, "base_ref": "main", "head_sha": HEAD}
    branches = [{"base": {"ref": ref}} for ref in ("main", "other", "main")]
    monkeypatch.setattr(gate, "api", Mock(side_effect=branches))
    for reason in ("merge-requested", "base-changed", "merge-failed"):
        artifact.write_text(json.dumps(decision), encoding="utf-8")
        if reason == "merge-requested":
            gate.merge()
        else:
            with pytest.raises(SystemExit, match="1"):
                gate.merge()
        assert json.loads(artifact.read_text(encoding="utf-8"))["reason"] == reason
