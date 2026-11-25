# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# cspell:ignore textconv Adraft

import json
import os
import runpy
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock, call, patch

import pytest
import yaml

from repo.private.tier0_approval import __main__ as gate

HEAD, BASE, REPO = "a" * 40, "b" * 40, "example/wiki"
BOT = {"login": "tbhb-dev-auto-reviews[bot]"}
WRITER = {"login": "writer"}
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
COMMIT = {"author": None, "committer": WRITER}
ACTIVITY = [[{"activity_type": "branch_deletion"}]]
EVIDENCE = ([[PULL]], PULL, COMMIT, ACTIVITY, PULL, {"id": 1})
ENV = {
    "GITHUB_REPOSITORY": REPO,
    "APP_SLUG": "tbhb-dev-auto-reviews",
    "CHECK_WORKFLOWS": "CI:123",
    "MAX_FILES": "1",
    "DESIGN_PATHS": "docs/design/**",
    "DESIGN_GO_SHA": "",
    "TIER0_PATHS": "**/*.md",
    "DENY_PATHS": ".github/**",
    "MODE": "evaluate",
}
SUCCESS = {"head_sha": HEAD, "conclusion": "success"}
WORKFLOW_RUN = SUCCESS | {"workflow_id": 123, "check_suite_id": 3}
CHECK = SUCCESS | {"name": "CI", "check_suite": {"id": 3}}
ARTIFACT = Path("tier0-decision.json")


def test_default_paths() -> None:
    workflow = Path(".github/workflows/tier0-approval.yml").read_text(encoding="utf-8")
    # PyYAML's safe loader uses the YAML 1.1 boolean key for "on".
    inputs = yaml.safe_load(workflow)[True]["workflow_call"]["inputs"]
    env = {key.upper(): inputs[key]["default"] for key in ("tier0_paths", "deny_paths")}
    for path in ("README.md", "README.MD", "docs/guide/intro.md", "LICENSE"):
        assert gate.tier0_path(path, env), path
    for path in (
        "AGENTS.override.md",
        "CLAUDE.local.md",
        "GEMINI.md",
        "LICENSE.py",
        "sub/.claude/skills/x/SKILL.md",
        ".agents/skills/x/SKILL.md",
        ".codex/prompts/x.md",
        ".cursor/rules/x.md",
        ".github/copilot-instructions.md",
        ".GitHub/notes.md",
        "sub/CODEOWNERS",
    ):
        assert not gate.tier0_path(path, env), path
    # Give CODEOWNERS an allow match so this assertion depends on the deny rule.
    assert not gate.tier0_path(
        "sub/CODEOWNERS", env | {"TIER0_PATHS": env["TIER0_PATHS"] + "\n**/CODEOWNERS"}
    )


@pytest.mark.parametrize(
    "path", ["docs/../README.md", "docs/./README.md", r"docs\x.md"]
)
def test_invalid_relative_path(path: str) -> None:
    assert not gate.tier0_path(path, ENV)


def test_absolute_path() -> None:
    assert not gate.tier0_path("/docs/README.md", ENV | {"TIER0_PATHS": "/**"})


@pytest.mark.parametrize(
    ("runs", "checks"),
    [
        ([], [CHECK]),
        ([WORKFLOW_RUN | {"conclusion": "failure"}], [CHECK]),
        ([WORKFLOW_RUN | {"head_sha": BASE}], [CHECK]),
        ([WORKFLOW_RUN | {"workflow_id": 124}], [CHECK]),
        ([WORKFLOW_RUN], [CHECK | {"name": "other"}]),
        ([WORKFLOW_RUN], [CHECK | {"head_sha": BASE}]),
        ([WORKFLOW_RUN], [CHECK | {"check_suite": {"id": 4}}]),
        ([WORKFLOW_RUN], [CHECK | {"conclusion": "failure"}]),
        ([WORKFLOW_RUN], [CHECK | {"conclusion": "skipped"}]),
        ([WORKFLOW_RUN], [CHECK, CHECK]),
        ([WORKFLOW_RUN], []),
    ],
)
def test_unsuccessful_context(
    monkeypatch: pytest.MonkeyPatch,
    runs: list[gate.Record],
    checks: list[gate.Record],
) -> None:
    api = Mock(side_effect=[{"workflow_runs": runs}, [{"check_runs": checks}]])
    monkeypatch.setattr(gate, "api", api)
    assert not gate.context_pass(REPO, HEAD, "CI:123")


@pytest.mark.parametrize("spec", ["", "  ", "CI", "CI:01", ":123"])
def test_invalid_context(monkeypatch: pytest.MonkeyPatch, spec: str) -> None:
    api = Mock()
    monkeypatch.setattr(gate, "api", api)
    assert not gate.contexts_pass(REPO, HEAD, spec)
    api.assert_not_called()


def test_contexts(monkeypatch: pytest.MonkeyPatch) -> None:
    stage = CHECK | {"name": "CI: stage"}
    pages = [{"check_runs": [CHECK]}, {"check_runs": [stage]}]
    runs = {"workflow_runs": [WORKFLOW_RUN]}
    request = Mock(side_effect=map(json.dumps, (runs, pages, {"workflow_runs": []})))
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    app_credential = "app-token"
    monkeypatch.setenv("GH_TOKEN", app_credential)
    monkeypatch.setenv("ACTIONS_TOKEN", "job-token")
    actions_env = os.environ | {"GH_TOKEN": "job-token"}
    assert not gate.contexts_pass(REPO, HEAD, " CI: stage : 123 \nOther:456")
    assert request.call_args_list == [
        call(
            (
                "gh",
                "api",
                f"repos/{REPO}/actions/workflows/123/runs?head_sha={HEAD}&per_page=1",
            ),
            encoding="utf-8",
            stderr=subprocess.PIPE,
            env=actions_env,
        ),
        call(
            (
                "gh",
                "api",
                f"repos/{REPO}/check-suites/3/check-runs?check_name=CI%3A+stage",
                "--paginate",
                "--slurp",
            ),
            encoding="utf-8",
            stderr=subprocess.PIPE,
            env=None,
        ),
        call(
            (
                "gh",
                "api",
                f"repos/{REPO}/actions/workflows/456/runs?head_sha={HEAD}&per_page=1",
            ),
            encoding="utf-8",
            stderr=subprocess.PIPE,
            env=actions_env,
        ),
    ]
    assert os.environ["GH_TOKEN"] == app_credential
    request.configure_mock(side_effect=map(json.dumps, (runs, pages)))
    assert gate.contexts_pass(REPO, HEAD, "CI: stage:123")


@pytest.mark.parametrize("token", [None, ""])
def test_missing_actions_token(
    monkeypatch: pytest.MonkeyPatch, token: str | None
) -> None:
    if token is None:
        monkeypatch.delenv("ACTIONS_TOKEN", raising=False)
    else:
        monkeypatch.setenv("ACTIONS_TOKEN", token)
    monkeypatch.setenv("GH_TOKEN", "app-token")
    request = Mock()
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    with pytest.raises(gate.HoldError, match=r"^missing-actions-token$"):
        gate.context_pass(REPO, HEAD, "CI:123")
    request.assert_not_called()


@pytest.mark.parametrize(
    ("old", "new", "counts", "regular"),
    [
        ("100644", "000000", "0\t1", True),
        ("000000", "100644", "1\t0", True),
        ("120000", "000000", "0\t1", False),
        ("000000", "100755", "1\t0", False),
        ("100644", "160000", "0\t1", False),
        ("100644", "100644", "-\t1", False),
        ("100644", "100644", "1\t-", False),
    ],
)
def test_changed_paths(
    monkeypatch: pytest.MonkeyPatch, old: str, new: str, counts: str, regular: bool
) -> None:
    raw = f":{old} {new} 777 000 M\0old.md\0:000000 100644 000 777 A\0 new\tname.md\0"
    diff = f"{raw}{counts}\told.md\x001\t0\t new\tname.md\0"
    command = Mock(side_effect=["", "", diff])
    monkeypatch.setattr(gate, "command", command)
    assert gate.changed_paths(REPO, BASE, HEAD) == (
        ["old.md", " new\tname.md"],
        regular,
    )
    git = ("git", "-C", command.call_args.args[2])
    credentials = (
        "-c",
        "credential.helper=",
        "-c",
        "credential.helper=!gh auth git-credential",
    )
    flags = "--raw --numstat -z --no-renames --no-ext-diff --no-textconv"
    assert command.call_args_list == [
        call(*git, "init", "--bare", "--quiet"),
        call(
            *git,
            *credentials,
            "fetch",
            "--quiet",
            "--no-tags",
            f"https://github.com/{REPO}.git",
            BASE,
            HEAD,
        ),
        call(
            *git,
            "diff",
            *flags.split(),
            "--ignore-submodules=none",
            "--merge-base",
            BASE,
            HEAD,
            "--",
        ),
    ]


@pytest.fixture
def api(monkeypatch: pytest.MonkeyPatch) -> Mock:
    request = Mock(side_effect=EVIDENCE)
    monkeypatch.setattr(gate, "api", request)
    monkeypatch.setattr(gate, "contexts_pass", Mock(return_value=True))
    monkeypatch.setattr(gate, "changed_paths", Mock(return_value=(["README.md"], True)))
    return request


@pytest.mark.parametrize(
    "patch",
    [{"sha": BASE}, {"ref": "other"}, {"repo": {"full_name": "other/wiki"}}],
)
def test_find_pull(api: Mock, patch: gate.Record) -> None:
    api.configure_mock(side_effect=[[[PULL | {"head": REF | patch}]]])
    with pytest.raises(gate.HoldError, match=r"^no-unique-open-pr$"):
        gate.find_pull(REPO, RUN, HEAD)


@pytest.mark.parametrize(
    ("patch", "reason"),
    [
        ({"head_sha": "bad"}, "invalid-sha"),
        ({"conclusion": "failure"}, "ci-unsuccessful"),
        ({"actor": BOT}, "approver-is-pusher"),
        ({"triggering_actor": BOT}, "approver-is-pusher"),
    ],
)
def test_run(api: Mock, patch: gate.Record, reason: str) -> None:
    assert gate.decide(RUN | patch, ENV) == {
        "decision": "hold",
        "reason": reason,
        "head_sha": "" if reason == "invalid-sha" else HEAD,
        "pr": None,
        "files": 0,
    }
    api.assert_not_called()


@pytest.mark.parametrize(
    ("index", "evidence", "reason"),
    [
        (0, [[PULL], [PULL]], "no-unique-open-pr"),
        (1, PULL | {"draft": True}, "not-eligible"),
        (2, COMMIT | {"author": BOT}, "approver-is-committer"),
        (2, COMMIT | {"committer": BOT}, "approver-is-committer"),
        (3, [[{"activity_type": "push"}]], "approver-is-pusher"),
        (4, PULL | {"head": REF | {"sha": BASE}}, "pr-changed"),
        (4, PULL | {"base": REF}, "pr-changed"),
        (4, PULL | {"state": "closed"}, "pr-changed"),
        (
            4,
            PULL | {"head": REF | {"repo": {"full_name": "fork/wiki"}}},
            "not-eligible",
        ),
        (4, PULL | {"labels": [{"name": "NO-AUTO-APPROVAL"}]}, "opted-out"),
        (4, PULL | {"user": BOT}, "approver-is-author"),
    ],
)
def test_evidence(api: Mock, index: int, evidence: object, reason: str) -> None:
    api.configure_mock(side_effect=(*EVIDENCE[:index], evidence))
    result = gate.decide(RUN, ENV | {"MODE": "enforce"})
    assert (result["decision"], result["reason"]) == ("hold", reason)
    assert api.call_count == index + 1


@pytest.mark.parametrize(
    ("changes", "overrides", "reason"),
    [
        (([], True), {}, "file-count"),
        ((["a.md", "b.md"], True), {}, "file-count"),
        ((["README.md"], False), {}, "unsupported-file"),
        ((["a.py"], True), {}, "path-outside-tier0"),
        ((["docs/DESIGN/x.md"], True), {}, "design-needs-go"),
        ((["docs/DESIGN/x.md"], True), {"DESIGN_GO_SHA": HEAD}, "tier0"),
        ((["README.md"], True), {"MODE": "bogus"}, "invalid-mode"),
    ],
)
def test_policy(
    api: Mock,
    monkeypatch: pytest.MonkeyPatch,
    changes: tuple[list[str], bool],
    overrides: dict[str, str],
    reason: str,
) -> None:
    diff = Mock(return_value=changes)
    monkeypatch.setattr(gate, "changed_paths", diff)
    result = gate.decide(RUN, ENV | overrides)
    diff.assert_called_once_with(REPO, BASE, HEAD)
    assert result["files"] == len(changes[0])
    assert (result["decision"], result["reason"]) == (
        "approve" if reason == "tier0" else "hold",
        reason,
    )
    assert api.call_count == 4


def test_failed_checks(api: Mock, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(gate, "contexts_pass", Mock(return_value=False))
    diff = Mock()
    monkeypatch.setattr(gate, "changed_paths", diff)
    assert gate.decide(RUN, ENV)["reason"] == "checks-unsuccessful"
    diff.assert_not_called()
    assert api.call_count == 4


def test_unexpected_approver(api: Mock) -> None:
    assert (
        gate.decide(RUN, ENV | {"APP_SLUG": "other"})["reason"] == "unexpected-approver"
    )
    api.assert_not_called()


def test_enforce(api: Mock, monkeypatch: pytest.MonkeyPatch) -> None:
    checks = Mock(return_value=True)
    monkeypatch.setattr(gate, "contexts_pass", checks)
    result = gate.decide(RUN, ENV | {"MODE": "enforce"})
    checks.assert_called_once_with(REPO, HEAD, ENV["CHECK_WORKFLOWS"])
    assert api.call_args_list == [
        call(
            REPO, "pulls", "--paginate", "--slurp", state="open", head="example:draft"
        ),
        call(REPO, "pulls/5"),
        call(REPO, f"commits/{HEAD}"),
        call(
            REPO,
            "activity",
            "--paginate",
            "--slurp",
            ref="refs/heads/draft",
            actor=BOT["login"],
        ),
        call(REPO, "pulls/5"),
        call(
            REPO,
            "pulls/5/reviews",
            "--method",
            "POST",
            "-f",
            f"commit_id={HEAD}",
            "-f",
            "event=APPROVE",
        ),
    ]
    assert result == {
        "decision": "approve",
        "reason": "tier0",
        "head_sha": HEAD,
        "pr": 5,
        "files": 1,
    }


@pytest.fixture
def files(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> dict[str, Mock]:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GITHUB_OUTPUT", "output")
    Path("output").write_text("previous=value\n", encoding="utf-8")
    names = (str(ARTIFACT), "output", "event")
    spies = {name: Mock(wraps=Path(name)) for name in names}
    monkeypatch.setattr(gate, "Path", spies.__getitem__)
    return spies


def test_main(
    monkeypatch: pytest.MonkeyPatch,
    files: dict[str, Mock],
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("GITHUB_EVENT_PATH", "event")
    monkeypatch.setenv("APP_SLUG", ENV["APP_SLUG"])
    Path("event").write_text(json.dumps({"workflow_run": RUN}), encoding="utf-8")
    request = Mock(
        side_effect=[json.dumps([[PULL]]), subprocess.CalledProcessError(1, "gh")]
    )
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    gate.main()
    endpoint = f"repos/{REPO}/pulls?state=open&head=example%3Adraft"
    assert request.call_args_list == [
        call(
            ("gh", "api", endpoint, "--paginate", "--slurp"),
            encoding="utf-8",
            stderr=subprocess.PIPE,
            env=None,
        ),
        call(
            ("gh", "api", f"repos/{REPO}/pulls/5?"),
            encoding="utf-8",
            stderr=subprocess.PIPE,
            env=None,
        ),
    ]
    artifact = ARTIFACT.read_text(encoding="utf-8")
    files["event"].read_text.assert_called_once_with(encoding="utf-8")
    files[str(ARTIFACT)].write_text.assert_called_once_with(artifact, encoding="utf-8")
    files["output"].open.assert_called_once_with("a", encoding="utf-8")
    assert json.loads(artifact) == {
        "decision": "hold",
        "reason": "evidence-or-command-failed",
        "head_sha": HEAD,
        "pr": 5,
        "files": 0,
    }
    assert capsys.readouterr().out == artifact
    previous = "previous=value\ndecision=hold\nreason=evidence-or-command-failed\n"
    assert Path("output").read_text(encoding="utf-8") == f"{previous}head_sha={HEAD}\n"


@pytest.mark.parametrize("arguments", [(), ("merge",)])
def test_enforce_cli_only_reviews(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, arguments: tuple[str, ...]
) -> None:
    script = str(Path(__file__).with_name("__main__.py"))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [script, *arguments])
    env = ENV | {
        "MODE": "enforce",
        "GITHUB_EVENT_PATH": "event",
        "GITHUB_OUTPUT": "output",
        "ACTIONS_TOKEN": "job-token",
    }
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    Path("event").write_text(json.dumps({"workflow_run": RUN}), encoding="utf-8")
    request = Mock(
        side_effect=[
            *map(json.dumps, EVIDENCE[:4]),
            json.dumps({"workflow_runs": [WORKFLOW_RUN]}),
            json.dumps([{"check_runs": [CHECK]}]),
            "",
            "",
            ":100644 100644 777 000 M\0README.md\x001\t0\tREADME.md\0",
            *map(json.dumps, EVIDENCE[4:]),
        ]
    )
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    with patch.object(Path, "open", autospec=True, side_effect=Path.open) as opened:
        runpy.run_path(script, run_name="__main__")

    gh_commands = [
        entry.args[0] for entry in request.call_args_list if entry.args[0][0] == "gh"
    ]
    assert all(args[:2] == ("gh", "api") for args in gh_commands)
    assert gh_commands[-1] == (
        "gh",
        "api",
        f"repos/{REPO}/pulls/5/reviews?",
        "--method",
        "POST",
        "-f",
        f"commit_id={HEAD}",
        "-f",
        "event=APPROVE",
    )
    opened_paths = {entry.args[0].name for entry in opened.call_args_list}
    assert "tier0-merge.json" not in opened_paths
    assert json.loads(ARTIFACT.read_text(encoding="utf-8"))["decision"] == "approve"
