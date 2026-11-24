# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import subprocess
from typing import TYPE_CHECKING
from unittest.mock import Mock

import pytest

from repo.private.tier0_approval import __main__ as approval

if TYPE_CHECKING:
    from pathlib import Path

type Evidence = tuple[Mock, Mock, Mock]

HEAD = "a" * 40
BASE = "b" * 40
REPO = "example/wiki"
RUN = {
    "head_sha": HEAD,
    "conclusion": "success",
    "head_branch": "draft",
    "head_repository": {"full_name": REPO},
}
PULL = {
    "number": 5,
    "state": "open",
    "base": {"sha": BASE},
    "head": {"sha": HEAD, "ref": "draft", "repo": {"full_name": REPO}},
    "labels": [{"name": "docs"}],
    "user": {"login": "writer"},
}
ENV = {
    "GITHUB_REPOSITORY": REPO,
    "APP_SLUG": "pins-approver",
    "CHECK_WORKFLOWS": "CI:123",
    "MAX_FILES": "50",
    "TIER0_PATHS": "**/*.md\ndocs/**\nLICENSE*",
    "DENY_PATHS": " \n.github/**\n**/CODEOWNERS",
    "DESIGN_PATHS": "",
    "DESIGN_GO_SHA": "",
    "MODE": "evaluate",
}
CHECK = {
    "head_sha": HEAD,
    "check_suite": {"id": 123},
    "name": "CI",
    "conclusion": "success",
}
WORKFLOW = {"head_sha": HEAD, "status": "completed", "check_suite_id": 123}


@pytest.mark.parametrize(
    ("config", "runs", "updates", "expected"),
    [
        ("", [WORKFLOW], {}, False),
        ("CI", [WORKFLOW], {}, False),
        ("CI:123", [WORKFLOW | {"status": "in_progress"}], {}, False),
        ("CI:123", [WORKFLOW], {"head_sha": BASE}, False),
        ("CI:123", [WORKFLOW], {"check_suite": {"id": 456}}, False),
        ("CI:123", [WORKFLOW], {"conclusion": "failure"}, False),
        ("CI:123", [WORKFLOW], {}, True),
        ("CI:123\nOther:456", [WORKFLOW], {}, False),
    ],
)
def test_contexts(
    monkeypatch: pytest.MonkeyPatch,
    config: str,
    runs: list[dict],
    updates: dict,
    expected: bool,
) -> None:
    response = [{"workflow_runs": runs}, [{"check_runs": [CHECK | updates]}]]
    api = Mock(side_effect=response * 2)
    monkeypatch.setattr(approval, "api", api)
    assert approval.contexts_pass(REPO, HEAD, config) is expected


@pytest.mark.parametrize(
    ("records", "regular"),
    [
        (
            (
                ":100644 000000 777 000 D\0old.md\0:000000 100644 000 777 A\0new.md\0"
                "0\t1\told.md\0"
                "1\t0\tnew.md\0"
            ),
            True,
        ),
        (":100644 100644 777 888 M\0old.md\0-\t-\told.md\0", False),
        (":160000 160000 777 888 M\0old.md\x001\t1\told.md\0", False),
    ],
)
def test_changed_paths(
    monkeypatch: pytest.MonkeyPatch, records: str, regular: bool
) -> None:
    command = Mock(side_effect=["", "", records])
    monkeypatch.setattr(approval, "command", command)
    expected = ["old.md", "new.md"] if regular else ["old.md"]
    assert approval.changed_paths(REPO, BASE, HEAD) == (expected, regular)
    assert command.call_args_list[1].args[-2:] == (BASE, HEAD)
    assert command.call_args.args[-4:] == ("--merge-base", BASE, HEAD, "--")


@pytest.fixture
def evidence(monkeypatch: pytest.MonkeyPatch) -> Evidence:
    api = Mock(side_effect=[[[PULL]], PULL])
    checks = Mock(return_value=True)
    paths = Mock(return_value=(["README.md"], True))
    monkeypatch.setattr(approval, "api", api)
    monkeypatch.setattr(approval, "contexts_pass", checks)
    monkeypatch.setattr(approval, "changed_paths", paths)
    return api, checks, paths


@pytest.mark.parametrize(
    ("updates", "reason"),
    [
        ({"head_sha": "bad"}, "invalid-sha"),
        ({"conclusion": "failure"}, "ci-unsuccessful"),
        ({"head_sha": BASE}, "no-unique-open-pr"),
    ],
)
def test_unmatched_run(evidence: Evidence, updates: dict, reason: str) -> None:
    assert approval.decide(RUN | updates, ENV)["reason"] == reason
    evidence[1].assert_not_called()


@pytest.mark.parametrize(
    ("paths", "regular", "env", "reason"),
    [
        ([], True, {}, "file-count"),
        (["a.md", "b.md"], True, {"MAX_FILES": "1"}, "file-count"),
        (["README.md"], False, {}, "unsupported-file"),
        (["old.py", "README.md"], True, {}, "path-outside-tier0"),
        ([".github/file.md"], True, {}, "path-outside-tier0"),
        (["docs/design.md"], True, {"DESIGN_PATHS": "docs/**"}, "design-needs-go"),
        (["docs/a"], True, {"DESIGN_PATHS": "docs/**", "DESIGN_GO_SHA": HEAD}, "tier0"),
        (["README.md"], True, {"MODE": "bogus"}, "invalid-mode"),
    ],
)
def test_policy(
    evidence: Evidence,
    paths: list[str],
    regular: bool,
    env: dict[str, str],
    reason: str,
) -> None:
    evidence[2].return_value = (paths, regular)
    result = approval.decide(RUN, ENV | env)
    assert result["reason"] == reason
    assert result["files"] == len(paths)


def test_ambiguous_or_failed_checks(evidence: Evidence) -> None:
    api, checks, _ = evidence
    api.side_effect = [[[PULL], [PULL]], [[PULL]], PULL]
    assert approval.decide(RUN, ENV)["reason"] == "no-unique-open-pr"
    checks.return_value = False
    assert approval.decide(RUN, ENV)["reason"] == "checks-unsuccessful"


@pytest.mark.parametrize(
    ("updates", "reason"),
    [
        ({"state": "closed"}, "pr-changed"),
        ({"head": {"sha": BASE}}, "pr-changed"),
        ({"labels": [{"name": "NO-AUTO-APPROVAL"}]}, "opted-out"),
        ({"user": {"login": "pins-approver[bot]"}}, "approver-is-author"),
    ],
)
def test_enforce_rechecks_pr(evidence: Evidence, updates: dict, reason: str) -> None:
    api = evidence[0]
    api.side_effect = [[[PULL]], PULL, PULL | updates]
    assert approval.decide(RUN, ENV | {"MODE": "enforce"})["reason"] == reason
    assert api.call_args.args == (REPO, "pulls/5")


@pytest.mark.parametrize("merge_fails", [True, False])
def test_enforce_sends_exact_sha(
    monkeypatch: pytest.MonkeyPatch,
    evidence: Evidence,
    *,
    merge_fails: bool,
) -> None:
    api = evidence[0]
    api.side_effect = [[[PULL]], PULL, PULL, {}]
    error = subprocess.CalledProcessError(1, "gh") if merge_fails else None
    command = Mock(side_effect=error)
    monkeypatch.setattr(approval, "command", command)
    result = approval.decide(RUN, ENV | {"MODE": "enforce"})
    assert api.call_args.args[-3:] == (f"commit_id={HEAD}", "-f", "event=APPROVE")
    command.assert_called_once_with(
        "gh",
        "pr",
        "merge",
        "5",
        "--repo",
        REPO,
        "--squash",
        "--match-head-commit",
        HEAD,
    )
    assert result["decision"] == "approve"
    assert result["reason"] == ("merge-failed" if merge_fails else "merge-requested")


def test_failed_api_artifact(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    error = subprocess.CalledProcessError(1, "gh")
    response = json.dumps([[PULL]])
    request = Mock(side_effect=[response, error])
    monkeypatch.setattr(approval.subprocess, "check_output", request)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("GITHUB_EVENT_PATH", "event.json")
    monkeypatch.setenv("GITHUB_OUTPUT", "output")
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    (tmp_path / "event.json").write_text(
        json.dumps({"workflow_run": RUN}), encoding="utf-8"
    )
    approval.main()
    args = request.call_args_list[0].args[0]
    assert args[:2] == ("gh", "api")
    assert args[2].startswith(f"repos/{REPO}/pulls?state=open&head=")
    artifact = json.loads(
        (tmp_path / "tier0-decision.json").read_text(encoding="utf-8")
    )
    assert json.loads(capsys.readouterr().out) == artifact
    assert artifact["reason"] == "evidence-or-command-failed"
    assert (tmp_path / "output").read_text(encoding="utf-8").splitlines() == [
        "decision=hold",
        "reason=evidence-or-command-failed",
        f"head_sha={HEAD}",
    ]
