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
BOT = {"login": "tbhb-dev-auto-reviews[bot]"}
WRITER = {"login": "writer"}
REF = {"sha": HEAD, "ref": "draft", "repo": {"full_name": REPO}}
RUN: gate.Record = {
    "head_sha": HEAD,
    "conclusion": "success",
    "head_branch": "draft",
    "head_repository": REF["repo"],
    "actor": WRITER,
    "triggering_actor": WRITER,
}
PULL = {
    "number": 5,
    "state": "open",
    "draft": False,
    "base": REF | {"sha": BASE},
    "head": REF,
    "labels": [{"name": "docs"}],
    "user": WRITER,
}
COMMIT = {"author": None, "committer": WRITER}
CLEAR = (COMMIT, [[{"activity_type": "branch_deletion"}]])
ENV = {
    "GITHUB_REPOSITORY": REPO,
    "APP_SLUG": "tbhb-dev-auto-reviews",
    "MODE": "evaluate",
    "CHECK_WORKFLOWS": "CI:123",
    "MAX_FILES": "2",
    "TIER0_PATHS": "**/*.md\ndocs/**",
    "DENY_PATHS": ".github/**",
    "DESIGN_PATHS": "docs/design/**",
    "DESIGN_GO_SHA": "",
}
WORKFLOW = {"head_sha": HEAD, "workflow_id": 123, "check_suite_id": 321}
CHECK = {"head_sha": HEAD, "name": "CI", "check_suite": {"id": 321}}
OUTSIDE = "path-outside-tier0"


def test_contexts(monkeypatch: pytest.MonkeyPatch) -> None:
    run, check = WORKFLOW | {"conclusion": "success"}, CHECK | {"conclusion": "success"}
    api = Mock()
    monkeypatch.setattr(gate, "api", api)
    for spec, runs, checks, expected in (
        ("", [run], [check], False),
        ("CI", [run], [check], False),
        ("CI:123", (), [check], False),
        ("CI:123", [run | {"head_sha": BASE}], [check], False),
        ("CI:123", [run | {"workflow_id": 124}], [check], False),
        ("CI:123", [run | {"conclusion": "failure"}], [check], False),
        ("CI:123", [run], (), False),
        ("CI:123", [run], [check | {"name": "other"}], False),
        ("CI:123", [run], [check | {"head_sha": BASE}], False),
        ("CI:123", [run], [check | {"check_suite": {"id": 456}}], False),
        ("CI:123", [run], [check | {"conclusion": "failure"}], False),
        ("CI:123", [run], [check | {"conclusion": "skipped"}], False),
        ("CI:123", [run], [check | {"conclusion": "cancelled"}], False),
        (" CI : 123 ", [run], [check], True),
        ("CI:123\nOther:456", [run], [check], False),
    ):
        api.configure_mock(
            side_effect=[
                {"workflow_runs": runs},
                [{"check_runs": checks}],
                {"workflow_runs": []},
            ]
        )
        assert gate.contexts_pass(REPO, HEAD, spec) is expected, (spec, runs, checks)


def test_changed_paths(monkeypatch: pytest.MonkeyPatch) -> None:
    for mode, count, regular in (
        ("100644", "1", True),
        ("160000", "1", False),
        ("100644", "-", False),
    ):
        raw = f":{mode} 000000 777 000 D\0old.md\0:000000 100644 000 777 A\0new.md\0"
        command = Mock(
            side_effect=["", "", f"{raw}0\t{count}\told.md\x001\t0\tnew.md\0"]
        )
        monkeypatch.setattr(gate, "command", command)
        assert gate.changed_paths(REPO, BASE, HEAD) == (["old.md", "new.md"], regular)
        assert command.call_args_list[1].args[-2:] == (BASE, HEAD)
        assert command.call_args.args[-4:] == ("--merge-base", BASE, HEAD, "--")


@pytest.fixture
def api(monkeypatch: pytest.MonkeyPatch) -> Mock:
    mock = Mock()
    monkeypatch.setattr(gate, "api", mock)
    monkeypatch.setattr(gate, "contexts_pass", Mock(return_value=True))
    monkeypatch.setattr(gate, "changed_paths", Mock(return_value=(["README.md"], True)))
    return mock


def test_policy(api: Mock, monkeypatch: pytest.MonkeyPatch) -> None:
    workflow = Path(".github/workflows/tier0-approval.yml").read_text(encoding="utf-8")
    # PyYAML's safe loader uses the YAML 1.1 boolean key for "on".
    deny = yaml.safe_load(workflow)[True]["workflow_call"]["inputs"]["deny_paths"]
    env = ENV | {"DENY_PATHS": f"\n{deny['default']}"}
    cases: tuple[tuple[list[str], bool, dict[str, str], str], ...] = (
        ([], True, {}, "file-count"),
        (["a.md", "b.md", "c.md"], True, {}, "file-count"),
        (["README.md"], False, {}, "unsupported-file"),
        (["old.py", "README.md"], True, {}, OUTSIDE),
        ([".GitHub/x.md"], True, {}, OUTSIDE),
        (["docs/Codeowners"], True, {}, OUTSIDE),
        (["docs/../.github/ci.yml"], True, {}, OUTSIDE),
        (["docs/./a.md"], True, {}, OUTSIDE),
        (["/docs/a.md"], True, {}, OUTSIDE),
        (["docs/a\\b.md"], True, {}, OUTSIDE),
        (["docs/DESIGN/a.md"], True, {}, "design-needs-go"),
        (["DOCS/DESIGN/a", "DOCS/b"], True, {"DESIGN_GO_SHA": HEAD}, "tier0"),
        (["README.md"], True, {"MODE": "bogus"}, "invalid-mode"),
    )
    for paths, regular, overrides, reason in cases:
        api.configure_mock(side_effect=[[[PULL]], PULL, *CLEAR])
        monkeypatch.setattr(gate, "changed_paths", Mock(return_value=(paths, regular)))
        result = gate.decide(RUN, env | overrides)
        assert (result["reason"], result["files"]) == (reason, len(paths))
        assert result["decision"] == ("approve" if reason == "tier0" else "hold")


def test_run(api: Mock) -> None:
    for patch, reason in (
        ({"head_sha": "bad"}, "invalid-sha"),
        ({"head_sha": BASE}, "no-unique-open-pr"),
        ({"conclusion": "failure"}, "ci-unsuccessful"),
        ({"actor": BOT}, "approver-is-pusher"),
        ({"triggering_actor": BOT}, "approver-is-pusher"),
    ):
        api.configure_mock(side_effect=[[[PULL]]])
        assert gate.decide(RUN | patch, ENV)["reason"] == reason
    assert (
        gate.decide(RUN, ENV | {"APP_SLUG": "other"})["reason"] == "unexpected-approver"
    )


def test_current(api: Mock) -> None:
    for patch, reason in (
        ({"state": "closed"}, "pr-changed"),
        ({"head": REF | {"sha": BASE}}, "pr-changed"),
        ({"base": REF}, "pr-changed"),
        ({"labels": [{"name": "NO-AUTO-APPROVAL"}]}, "opted-out"),
        ({"user": BOT}, "approver-is-author"),
        ({"draft": True}, "not-eligible"),
        ({"head": REF | {"repo": {"full_name": "fork/wiki"}}}, "not-eligible"),
    ):
        api.configure_mock(side_effect=[[[PULL]], PULL, *CLEAR, PULL | patch])
        assert gate.decide(RUN, ENV | {"MODE": "enforce"})["reason"] == reason
    api.configure_mock(side_effect=[[[PULL]], PULL | {"draft": True}])
    assert gate.decide(RUN, ENV)["reason"] == "not-eligible"


def test_evidence(api: Mock, monkeypatch: pytest.MonkeyPatch) -> None:
    for role in ("author", "committer"):
        api.configure_mock(side_effect=[[[PULL]], PULL, COMMIT | {role: BOT}])
        assert gate.decide(RUN, ENV)["reason"] == "approver-is-committer"
    activity = [[{"activity_type": "push"}]]
    api.configure_mock(side_effect=[[[PULL]], PULL, COMMIT, activity])
    assert gate.decide(RUN, ENV)["reason"] == "approver-is-pusher"
    api.configure_mock(side_effect=[[[PULL], [PULL]], [[PULL]], PULL, *CLEAR])
    monkeypatch.setattr(gate, "contexts_pass", Mock(return_value=False))
    assert gate.decide(RUN, ENV)["reason"] == "no-unique-open-pr"
    assert gate.decide(RUN, ENV)["reason"] == "checks-unsuccessful"


def test_enforce(api: Mock, monkeypatch: pytest.MonkeyPatch) -> None:
    flags = ("--repo", REPO, "--squash", "--match-head-commit")
    for error in (None, subprocess.CalledProcessError(1, "gh")):
        api.configure_mock(side_effect=[[[PULL]], PULL, *CLEAR, PULL, {}])
        command = Mock(side_effect=error)
        monkeypatch.setattr(gate, "command", command)
        result = gate.decide(RUN, ENV | {"MODE": "enforce"})
        assert api.call_args.args[1] == "pulls/5/reviews"
        assert api.call_args.args[-3:] == (f"commit_id={HEAD}", "-f", "event=APPROVE")
        command.assert_called_once_with("gh", "pr", "merge", "5", *flags, HEAD)
        assert result["decision"] == "approve"
        assert result["reason"] == ("merge-failed" if error else "merge-requested")


def test_artifact(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    request = Mock(
        side_effect=[json.dumps([[PULL]]), subprocess.CalledProcessError(1, "gh")]
    )
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("GITHUB_EVENT_PATH", "event")
    monkeypatch.setenv("GITHUB_OUTPUT", "output")
    for key, value in ENV.items():
        monkeypatch.setenv(key, value)
    Path("event").write_text(json.dumps({"workflow_run": RUN}), encoding="utf-8")
    gate.main()
    assert request.call_args_list[0].args[0][:2] == ("gh", "api")
    artifact = json.loads(Path("tier0-decision.json").read_text(encoding="utf-8"))
    assert artifact["reason"] == "evidence-or-command-failed"
    output = "decision=hold\nreason=evidence-or-command-failed\n"
    assert Path("output").read_text(encoding="utf-8") == f"{output}head_sha={HEAD}\n"
