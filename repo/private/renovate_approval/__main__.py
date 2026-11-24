# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run the approval workflow from the verified rules checkout."""

import json
import os
import sys
from collections.abc import Callable, Mapping  # noqa: TC003 - Python 3.11
from pathlib import Path

if __name__ == "__main__":
    sys.path.append(str(Path(__file__).resolve().parents[3]))

from repo.private.renovate_approval.approve import approve, refuse
from repo.private.renovate_approval.decide import Decision, decide
from repo.private.renovate_approval.gather import (
    BYTES_PER_MEGABYTE,
    Facts,
    GitHub,
    GitRunner,
    Session,
    Trigger,
    checks_for,
    download_digest,
    git_diff,
    pin_facts,
    run_git,
)
from repo.private.renovate_approval.matcher import (
    RefusalError,
    _present,
    _require,
    _strings,
    config_from,
)


def _settings(lines: str) -> list[tuple[str, str]]:
    entries = []
    for line in lines.splitlines():
        if not line.strip():
            continue
        key, separator, value = line.rpartition(":")
        _require(separator and key.strip() and value.strip(), "parse_doubt")
        entries.append((key.strip(), value.strip()))
    return entries


def _config(env: Mapping[str, str]) -> dict[str, object]:
    config: dict[str, object] = {}
    for key in ("allowed_bumps", "first_party_owners"):
        if (value := env.get(f"RA_{key.upper()}")) is not None:
            config[key] = value.split()
    for key in ("first_party_modules", "registry", "opt_out_label"):
        if (value := env.get(f"RA_{key.upper()}")) is not None:
            config[key] = value
    for key in ("max_files", "max_commits"):
        if (value := env.get(f"RA_{key.upper()}")) is not None:
            config[key] = int(value)
    globs: dict[str, list[str]] = {}
    for kind, pattern in _settings(env.get("RA_PIN_FILES", "")):
        globs.setdefault(kind, []).append(pattern)
    config["pin_files"] = globs
    config_from({"config": config})
    return config


def _workflows(lines: str) -> dict[str, int]:
    workflows: dict[str, int] = {}
    for context, workflow in _settings(lines):
        number = int(workflow)
        _require(number > 0 and context not in workflows, "required_check_unbound")
        workflows[context] = number
    return workflows


def _evaluate(
    session: Session,
    runner: GitRunner,
    download: Callable[[str, int], str | None],
    *,
    enforce: bool,
) -> Decision:
    pull = session.initial()
    base = _present(session.base, "api_error")
    metadata = session.metadata(pull, base)
    files = _strings(metadata["files"], "file_list_mismatch")
    diff = git_diff(session, pull.head, base.merge_base, files, runner)
    metadata.update(
        modes=diff.modes, texts=diff.texts, has_mise_lock=diff.has_mise_lock
    )
    checks = checks_for(session, pull, base)
    decision = decide(diff.patch, metadata, checks)
    needed: dict[str, set[int]] = {}
    for finding in decision.findings:
        if finding.code == "fact_missing":
            needed.setdefault(finding.path, set()).add(finding.line)
    if needed:
        evidence = Facts(session.api, download, session.max_download_bytes)
        metadata["facts"] = pin_facts(diff.patch.decode(), metadata, needed, evidence)
        decision = decide(diff.patch, metadata, checks)
    return approve(session, pull, base, decision, enforce=enforce)


def _report(
    mode: str, session: Session | None, decision: Decision
) -> dict[str, object]:
    return {
        "mode": mode,
        "pull_request": session.number if session else None,
        "head_sha": session.trigger.head if session else "",
        "base_snapshot": session.base.json() if session and session.base else None,
        "ci_run_id": session.trigger.run_id if session else None,
        "ci_run_attempt": session.trigger.attempt if session else None,
        "read_times": session.read_times if session else [],
        "decision": "approve" if decision.approve else "refuse",
        "reason": decision.reason,
        "findings": [finding._asdict() for finding in decision.findings],
    }


def _emit(env: Mapping[str, str], report: dict[str, object]) -> None:
    artifact = json.dumps(report, indent=2, ensure_ascii=True)
    errors: list[OSError] = []
    try:
        if directory := env.get("RA_OUTPUT_DIR"):
            path = Path(directory)
            path.mkdir(parents=True, exist_ok=True)
            (path / "decision.json").write_text(artifact + "\n", encoding="utf-8")
    except OSError as error:
        errors.append(error)
    # An indented code block keeps untrusted paths and findings inert in Markdown.
    summary = (
        "## Renovate auto-approval\n\n"
        + "\n".join(f"    {line}" for line in artifact.splitlines())
        + "\n"
    )
    outputs = "".join(
        f"{key}={report[key]}\n" for key in ("decision", "reason", "head_sha")
    )
    for key, content in (("GITHUB_STEP_SUMMARY", summary), ("GITHUB_OUTPUT", outputs)):
        try:
            if destination := env.get(key):
                with Path(destination).open("a", encoding="utf-8") as stream:
                    stream.write(content)
        except OSError as error:
            errors.append(error)
    if errors:
        print("Renovate auto-approval could not write its report.", file=sys.stderr)  # noqa: T201


def main(
    env: Mapping[str, str] = os.environ,
    api: GitHub | None = None,
    runner: GitRunner = run_git,
    download: Callable[[str, int], str | None] = download_digest,
) -> int:
    mode = env.get("RA_MODE", "evaluate")
    session = None
    try:
        _require(mode in ("evaluate", "enforce"), "parse_doubt")
        event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_bytes())
        trigger = Trigger.read(env["GITHUB_REPOSITORY"], event)
        client = api if api is not None else GitHub(env["GH_TOKEN"])
        client.repository_id = trigger.repository_id
        config = _config(env)
        workflows = _workflows(env.get("RA_CHECK_WORKFLOWS", ""))
        limit = int(env.get("RA_MAX_DOWNLOAD_MB", "256"))
        _require(limit > 0, "parse_doubt")
        session = Session(
            client, trigger, config, workflows, limit * BYTES_PER_MEGABYTE
        )
        decision = _evaluate(session, runner, download, enforce=mode == "enforce")
    except RefusalError as error:
        decision = refuse(error.code)
    except Exception:  # noqa: BLE001 - the workflow records unexpected failures
        # Exception text can contain credentials or pull request content.
        decision = refuse("internal_error")
    _emit(env, _report(mode, session, decision))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
