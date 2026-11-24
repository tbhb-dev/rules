# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# cspell:ignore textconv Adraft

import json
import subprocess
from pathlib import Path
from unittest.mock import Mock, call

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
    "base": REF | {"sha": BASE, "ref": "main"},
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
WORKFLOW_PATH = Path(".github/workflows/tier0-approval.yml")
ARTIFACT = "tier0-decision.json"


def test_contexts(monkeypatch: pytest.MonkeyPatch) -> None:
    run, check = WORKFLOW | {"conclusion": "success"}, CHECK | {"conclusion": "success"}
    api = Mock()
    monkeypatch.setattr(gate, "api", api)
    for spec, runs, checks, expected in (
        ("", [run], [check], False),
        ("   ", [run], [check], False),
        ("CI", [run], [check], False),
        ("CI:01", [run], [check], False),
        (":123", [run], [check], False),
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
        ("CI:123", [run], [check, check], False),
        (" CI : 123 ", [run], [check], True),
        ("CI: stage:123\nOther:456", [run], [check | {"name": "CI: stage"}], False),
    ):
        api.reset_mock()
        api.configure_mock(
            side_effect=[
                {"workflow_runs": runs},
                [{"check_runs": checks}],
                {"workflow_runs": []},
            ]
        )
        assert gate.contexts_pass(REPO, HEAD, spec) is expected, (spec, runs, checks)
        if spec in {"", "   ", "CI", "CI:01", ":123"}:
            api.assert_not_called()
    assert api.call_args_list == [
        call(REPO, "actions/workflows/123/runs", head_sha=HEAD, per_page="1"),
        call(
            REPO,
            "check-suites/321/check-runs",
            "--paginate",
            "--slurp",
            check_name="CI: stage",
        ),
        call(REPO, "actions/workflows/456/runs", head_sha=HEAD, per_page="1"),
    ]


def test_changed_paths(monkeypatch: pytest.MonkeyPatch) -> None:
    for old, new, counts, regular in (
        ("100644", "000000", "0\t1", True),
        ("000000", "100644", "1\t0", True),
        ("120000", "000000", "0\t1", False),
        ("000000", "100755", "1\t0", False),
        ("100644", "160000", "0\t1", False),
        ("100644", "100644", "-\t1", False),
        ("100644", "100644", "1\t-", False),
    ):
        raw = (
            f":{old} {new} 777 000 M\0old.md\0:000000 100644 000 777 A\0 new\tname.md\0"
        )
        diff = f"{raw}{counts}\told.md\x001\t0\t new\tname.md\0"
        command = Mock(side_effect=["", "", diff])
        monkeypatch.setattr(gate, "command", command)
        assert gate.changed_paths(REPO, BASE, HEAD) == (
            ["old.md", " new\tname.md"],
            regular,
        )
        git = ("git", "-C", command.call_args.args[2])
        fetch = (
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
                *fetch,
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
    mock = Mock()
    monkeypatch.setattr(gate, "api", mock)
    monkeypatch.setattr(gate, "contexts_pass", Mock(return_value=True))
    monkeypatch.setattr(gate, "changed_paths", Mock(return_value=(["README.md"], True)))
    return mock


def default_paths() -> dict[str, str]:
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    # PyYAML's safe loader uses the YAML 1.1 boolean key for "on".
    inputs = yaml.safe_load(workflow)[True]["workflow_call"]["inputs"]
    return {
        key.upper(): inputs[key]["default"] for key in ("tier0_paths", "deny_paths")
    }


def test_default_paths() -> None:
    env = default_paths()
    assert all(
        gate.tier0_path(path, env)
        for path in (
            "README.md",
            "docs/guide/intro.md",
            "docs/guide/intro.txt",
            "LICENSE",
        )
    )
    assert not any(
        gate.tier0_path(path, env)
        for path in (
            "AGENTS.md",
            "CLAUDE.md",
            "sub/AGENTS.md",
            "sub/CLAUDE.md",
            ".claude/commands/review.md",
            "docs/build.sh",
            "docs/build.yml",
        )
    )


def test_policy(api: Mock, monkeypatch: pytest.MonkeyPatch) -> None:
    deny = default_paths()["DENY_PATHS"]
    env = ENV | {"DENY_PATHS": f"\n{deny}"}
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
        diff = Mock(return_value=(paths, regular))
        monkeypatch.setattr(gate, "changed_paths", diff)
        result = gate.decide(RUN, env | overrides)
        diff.assert_called_once_with(REPO, BASE, HEAD)
        assert (result["reason"], result["files"]) == (reason, len(paths))
        assert result["decision"] == ("approve" if reason == "tier0" else "hold")


def test_run(api: Mock) -> None:
    for patch, reason in (
        ({"head_sha": BASE}, "no-unique-open-pr"),
        ({"conclusion": "failure"}, "ci-unsuccessful"),
        ({"actor": BOT}, "approver-is-pusher"),
        ({"triggering_actor": BOT}, "approver-is-pusher"),
    ):
        api.configure_mock(side_effect=[[[PULL]]])
        assert gate.decide(RUN | patch, ENV)["reason"] == reason
    assert gate.decide(RUN | {"head_sha": "bad"}, ENV) == {
        "decision": "hold",
        "reason": "invalid-sha",
        "head_sha": "",
        "pr": None,
        "files": 0,
    }
    assert (
        gate.decide(RUN, ENV | {"APP_SLUG": "other"})["reason"] == "unexpected-approver"
    )
    for ref in (REF | {"ref": "other"}, REF | {"repo": {"full_name": "other/wiki"}}):
        api.configure_mock(side_effect=[[[PULL | {"head": ref}]]])
        assert gate.decide(RUN, ENV)["reason"] == "no-unique-open-pr"


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
    checks = Mock(return_value=True)
    monkeypatch.setattr(gate, "contexts_pass", checks)
    api.configure_mock(side_effect=[[[PULL]], PULL, *CLEAR, PULL, {}])
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
        "base_ref": "main",
    }

    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    steps = yaml.safe_load(workflow)["jobs"]["approval"]["steps"]
    app, decide, merge = (step for step in steps if "id" in step)
    assert app["with"]["permission-contents"] == "read"
    assert decide["env"]["GH_TOKEN"] == "${{ steps.app.outputs.token }}"  # noqa: S105
    assert merge["env"] == {"GH_TOKEN": "${{ github.token }}"}
    assert merge["run"] == f"{decide['run']} merge"
    approved = "steps.decide.outputs.decision == 'approve'"
    assert merge["if"] == f"inputs.mode == 'enforce' && {approved}"


@pytest.fixture
def files(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> dict[str, Mock]:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("GITHUB_OUTPUT", "output")
    Path("output").write_text("previous=value\n", encoding="utf-8")
    names = (ARTIFACT, "tier0-merge.json", "output", "event")
    spies = {name: Mock(wraps=Path(name)) for name in names}
    monkeypatch.setattr(gate, "Path", spies.__getitem__)
    return spies


@pytest.mark.parametrize(
    ("branch", "reason"),
    [
        ("main", "merge-requested"),
        ("other", "base-changed"),
        ("main", "merge-failed"),
    ],
)
def test_merge(
    api: Mock,
    monkeypatch: pytest.MonkeyPatch,
    files: dict[str, Mock],
    branch: str,
    reason: str,
) -> None:
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    path = Path(ARTIFACT)
    decision = {"pr": 5, "base_ref": "main", "head_sha": HEAD, "reason": "tier0"}
    path.write_text(json.dumps(decision), encoding="utf-8")
    command = Mock()
    if reason == "merge-failed":
        command.side_effect = subprocess.CalledProcessError(1, "gh")
    monkeypatch.setattr(gate, "command", command)
    api.return_value = {"base": {"ref": branch}}
    if reason == "merge-requested":
        gate.merge()
    else:
        with pytest.raises(SystemExit) as error:
            gate.merge()
        assert error.value.code == 1
    api.assert_called_once_with(REPO, "pulls/5")
    if branch == "main":
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
    else:
        command.assert_not_called()
    artifact = f"{json.dumps(decision | {'reason': reason})}\n"
    files[ARTIFACT].read_text.assert_called_once_with(encoding="utf-8")
    pending = files["tier0-merge.json"]
    pending.write_text.assert_called_once_with(artifact, encoding="utf-8")
    pending.replace.assert_called_once_with(ARTIFACT)
    files["output"].open.assert_called_once_with("a", encoding="utf-8")
    assert path.read_text(encoding="utf-8") == artifact
    assert (
        Path("output").read_text(encoding="utf-8")
        == f"previous=value\nreason={reason}\n"
    )


def test_artifact(
    monkeypatch: pytest.MonkeyPatch,
    files: dict[str, Mock],
    capsys: pytest.CaptureFixture[str],
) -> None:
    request = Mock(
        side_effect=[json.dumps([[PULL]]), subprocess.CalledProcessError(1, "gh")]
    )
    monkeypatch.setattr(gate.subprocess, "check_output", request)
    monkeypatch.setenv("GITHUB_EVENT_PATH", "event")
    for key, value in ENV.items():
        monkeypatch.setenv(key, value)
    Path("event").write_text(json.dumps({"workflow_run": RUN}), encoding="utf-8")
    gate.main()
    endpoint = f"repos/{REPO}/pulls?state=open&head=example%3Adraft"
    assert request.call_args_list == [
        call(
            ("gh", "api", endpoint, "--paginate", "--slurp"),
            encoding="utf-8",
            stderr=subprocess.PIPE,
        ),
        call(
            ("gh", "api", f"repos/{REPO}/pulls/5?"),
            encoding="utf-8",
            stderr=subprocess.PIPE,
        ),
    ]
    artifact = Path(ARTIFACT).read_text(encoding="utf-8")
    files["event"].read_text.assert_called_once_with(encoding="utf-8")
    files[ARTIFACT].write_text.assert_called_once_with(artifact, encoding="utf-8")
    files["output"].open.assert_called_once_with("a", encoding="utf-8")
    assert json.loads(artifact) == {
        "decision": "hold",
        "reason": "evidence-or-command-failed",
        "head_sha": HEAD,
        "pr": 5,
        "files": 0,
    }
    assert capsys.readouterr().out == artifact
    output = "previous=value\ndecision=hold\nreason=evidence-or-command-failed\n"
    assert Path("output").read_text(encoding="utf-8") == f"{output}head_sha={HEAD}\n"
