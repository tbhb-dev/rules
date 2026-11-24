# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Decide using only a verified checkout's gathered evidence.

diff is a UTF-8 str or bytes containing the zero-context Git patch. metadata
and checks are JSON objects. Positive GitHub IDs and counts are integers.
metadata contains these keys:

* pr_count, state, draft, base_ref, default_branch, base_repo, head_repo,
  labels (strings), author ({id, login, type}), author_app_id (integer or
  null when GitHub omits attribution), and commits ([{author_id, committer,
  verified}]). Repository names come from GitHub's full_name.
* files is the list of GitHub changed paths. For a rename or copy use the
  destination path. modes maps each patch path to [old_mode, new_mode] as
  six-digit strings from the raw diff. texts maps each pin path to
  {base, head} with complete UTF-8 text. has_mise_lock describes the base
  tree and is required for mise.toml updates.
* config optionally overrides max_files, max_commits, opt_out_label,
  allowed_bumps (list), first_party_owners (list), first_party_modules
  (glob), registry (URL), and pin_files (kind to list of path globs).
  Canonical kinds are workflow, starlark, mise, mise_lock, and bazel_lock.
  Omitted kinds keep their defaults. Overrides intersect built-in globs.
* facts optionally maps paths to decimal head line numbers to objects.
  See matcher for the fields and their binding.

checks contains required ([{name, app_id, workflow_id}]), snapshot
({workflow_id, run_id, attempt, suite_id}), runs ([{name, app_id,
workflow_id, run_id, attempt, suite_id, status, conclusion}]), and rules
({required_approving_review_count, dismiss_stale_reviews_on_push,
require_last_push_approval}). approver_check is the caller's approving
check name. The gatherer verifies the snapshot belongs to this PR and
applies the suite head or verified merge-commit binding before supplying it.

RefusalErrors are ordered by stage (pull request, diff summary, file findings,
checks). File findings sort by path and then line, with line 0 for the
whole file. Run-wide findings use an empty path and line 0.
"""

from dataclasses import dataclass
from typing import Final, cast

from .matcher import (
    Finding,
    RefusalError,
    config_from,
    match_patch,
    objects,
    positive_id,
)

RENOVATE_APP_ID: Final = 3915812
RENOVATE_BOT_ID: Final = 289255489
RENOVATE_LOGIN: Final = "tbhb-dev-renovate[bot]"
MAX_DIFF_BYTES: Final = 1024 * 1024

# The codes shared with later stages are listed here for the decision log.
REASON_CODES: Final = {
    "approve": ("ok_pin_only",),
    "pull_request": (
        "pr_not_unique",
        "pr_not_open",
        "pr_draft",
        "base_not_default",
        "fork_head",
        "opted_out",
        "author_not_renovate",
        "author_app_mismatch",
        "commit_not_renovate",
        "signature_unverified",
        "too_many_commits",
    ),
    "diff": (
        "empty_diff",
        "too_many_files",
        "diff_too_large",
        "file_list_mismatch",
        "not_a_pin_file",
        "self_pin",
        "rename",
        "copy",
        "new_file",
        "deleted_file",
        "mode_change",
        "binary",
        "submodule_or_symlink",
        "eol_change",
        "encoding",
        "line_added",
        "line_removed",
        "line_count_changed",
        "not_a_pin_line",
        "mixed_line_kinds",
        "key_changed",
        "no_value_change",
        "parse_doubt",
    ),
    "pins": (
        "comment_only_change",
        "unversioned_pin",
        "unpinned_version",
        "unparsed_version",
        "downgrade",
        "bump_level_not_allowed",
        "digest_without_version_change",
        "digest_not_updated",
        "digest_mismatch",
        "url_changed_beyond_version",
        "tag_mismatch",
        "not_first_party",
        "not_merged_at_source",
    ),
    "lockfiles": (
        "lock_not_updated",
        "lock_changed_without_pin",
        "lock_version_mismatch",
        "lock_key_changed",
        "lock_asset_mismatch",
    ),
    "checks": (
        "checks_pending",
        "check_skipped",
        "check_neutral",
        "check_failed",
        "check_missing",
        "required_check_unbound",
        "multiple_required_workflows",
        "no_required_checks",
        "self_check_required",
        "stale_dismissal_off",
    ),
    # Although gathering supplies these facts, matcher consumption can discover
    # that the snapshot lacks a usable fact or the download failed.
    "pin_evidence": ("fact_missing", "digest_unverifiable"),
    "other_stages": (
        "already_approved",
        "head_mismatch_at_start",
        "head_moved",
        "head_moved_after_approval",
        "base_changed",
        "base_changed_after_approval",
        "api_error",
        "rate_limited",
        "pagination_truncated",
        "diff_unavailable",
        "approval_failed",
        "dismissal_failed",
        "internal_error",
    ),
}


@dataclass(frozen=True)
class Decision:
    reason: str
    findings: list[Finding]

    @property
    def approve(self) -> bool:
        return self.reason == "ok_pin_only" and not self.findings


def _pull_request(metadata: dict[str, object]) -> list[Finding]:
    config = config_from(metadata)
    commits = objects(metadata.get("commits"))
    author = metadata.get("author")
    app_id = metadata.get("author_app_id", 0)
    labels = metadata.get("labels")
    base_ref, base_repo = metadata.get("base_ref"), metadata.get("base_repo")
    count = metadata.get("pr_count")
    conditions = (
        (type(count) is int and count == 1, "pr_not_unique"),
        (metadata.get("state") == "open", "pr_not_open"),
        (metadata.get("draft") is False, "pr_draft"),
        (_same_text(base_ref, metadata.get("default_branch")), "base_not_default"),
        (_same_text(base_repo, metadata.get("head_repo")), "fork_head"),
        (
            isinstance(labels, list)
            and all(isinstance(label, str) for label in cast("list[object]", labels))
            and config.opt_out_label not in labels,
            "opted_out",
        ),
        (
            isinstance(author, dict)
            and author
            == {
                "id": RENOVATE_BOT_ID,
                "login": RENOVATE_LOGIN,
                "type": "Bot",
            }
            and type(author["id"]) is int,
            "author_not_renovate",
        ),
        (
            app_id is None or (type(app_id) is int and app_id == RENOVATE_APP_ID),
            "author_app_mismatch",
        ),
        (len(commits) <= config.max_commits, "too_many_commits"),
        (
            bool(commits) and all(_renovate_commit(commit) for commit in commits),
            "commit_not_renovate",
        ),
        (
            all(commit.get("verified") is True for commit in commits),
            "signature_unverified",
        ),
    )
    return [Finding(code, "", 0, "") for passed, code in conditions if not passed]


def _same_text(left: object, right: object) -> bool:
    return isinstance(left, str) and bool(left) and left == right


def _renovate_commit(commit: dict[str, object]) -> bool:
    author = commit.get("author_id")
    return (
        type(author) is int
        and author == RENOVATE_BOT_ID
        and commit.get("committer") == "web-flow"
    )


_BINDING = ("workflow_id", "run_id", "attempt", "suite_id")
_PENDING = frozenset({"queued", "in_progress", "waiting", "requested", "pending"})
_CONCLUSION_CODES = {
    "success": None,
    "skipped": "check_skipped",
    "neutral": "check_neutral",
    "failure": "check_failed",
    "cancelled": "check_failed",
    "timed_out": "check_failed",
    "action_required": "check_failed",
    "stale": "check_failed",
    "startup_failure": "check_failed",
}


def _check_status(run: dict[str, object]) -> str | None:
    status, conclusion = run.get("status"), run.get("conclusion")
    if status == "completed" and isinstance(conclusion, str):
        return _CONCLUSION_CODES.get(conclusion, "check_failed")
    if isinstance(status, str) and status in _PENDING:
        return "checks_pending"
    return "check_failed"


def _required_checks(checks: dict[str, object]) -> list[Finding]:
    required = objects(checks.get("required"), "required_check_unbound")
    if not required:
        return [Finding("no_required_checks", "", 0, "")]
    findings: list[Finding] = []
    workflows: set[object] = set()
    approver = checks.get("approver_check")
    for rule in required:
        name = rule.get("name")
        if (
            not isinstance(name, str)
            or not name
            or not all(positive_id(rule.get(key)) for key in ("app_id", "workflow_id"))
        ):
            findings.append(Finding("required_check_unbound", "", 0, str(name)))
            continue
        workflows.add(rule["workflow_id"])
        if not isinstance(approver, str) or not approver or name == approver:
            findings.append(Finding("self_check_required", "", 0, name))
    if len(workflows) > 1:
        findings.append(Finding("multiple_required_workflows", "", 0, ""))
    if findings:
        return findings
    return _check_runs(checks, required)


def _check_runs(
    checks: dict[str, object], required: list[dict[str, object]]
) -> list[Finding]:
    snapshot = checks.get("snapshot")
    if not isinstance(snapshot, dict) or not all(
        positive_id(snapshot.get(key)) for key in _BINDING
    ):
        return [Finding("check_missing", "", 0, "invalid CI snapshot")]
    runs = objects(checks.get("runs"), "check_missing")
    findings = []
    for rule in required:
        matches = [run for run in runs if _bound_check(run, rule, snapshot)]
        code = _check_status(matches[0]) if len(matches) == 1 else "check_missing"
        if code is not None:
            findings.append(Finding(code, "", 0, str(rule["name"])))
    return findings


def _bound_check(
    run: dict[str, object], rule: dict[str, object], snapshot: dict[str, object]
) -> bool:
    return (
        run.get("name") == rule["name"]
        and all(positive_id(run.get(key)) for key in (*_BINDING, "app_id"))
        and run["app_id"] == rule["app_id"]
        and run["workflow_id"] == rule["workflow_id"]
        and all(run[key] == snapshot[key] for key in _BINDING)
    )


def _checks(checks: dict[str, object]) -> list[Finding]:
    findings = _required_checks(checks)
    rules = checks.get("rules")
    if not isinstance(rules, dict) or not (
        positive_id(rules.get("required_approving_review_count"))
        and rules.get("dismiss_stale_reviews_on_push") is True
        and rules.get("require_last_push_approval") is True
    ):
        findings.append(Finding("stale_dismissal_off", "", 0, ""))
    return findings


def _diff_text(diff: str | bytes) -> str:
    try:
        encoded = diff.encode() if isinstance(diff, str) else diff
        if len(encoded) > MAX_DIFF_BYTES:
            msg = "diff_too_large"
            raise RefusalError(msg)
        text = encoded.decode()
    except UnicodeError as error:
        msg = "encoding"
        raise RefusalError(msg) from error
    if "\r" in text or "\x00" in text:
        msg = "encoding"
        raise RefusalError(msg)
    return text


def decide(
    diff: str | bytes, metadata: dict[str, object], checks: dict[str, object]
) -> Decision:
    findings: list[Finding] = []
    for stage in (
        lambda: _pull_request(metadata),
        lambda: match_patch(_diff_text(diff), metadata),
        lambda: _checks(checks),
    ):
        try:
            findings.extend(stage())
        except RefusalError as refusal:
            findings.append(Finding(refusal.code, "", 0, refusal.detail))
    return Decision(findings[0].code if findings else "ok_pin_only", findings)
