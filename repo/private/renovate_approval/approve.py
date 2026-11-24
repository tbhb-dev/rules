# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Revalidate the decision and bind the App's review to the checked snapshot."""

import json
from dataclasses import dataclass
from typing import Self

from .decide import Decision, _checks
from .gather import APPROVER, APIError, Base, Pull, Session, _integer, _sha, checks_for
from .matcher import Finding, RefusalError, _object, _require, _string, config_from

_MARKER = "Renovate pin approval snapshot v1\n"


def refuse(code: str, *additional: str) -> Decision:
    return Decision(
        code, [Finding(reason, "", 0, "") for reason in (code, *additional)]
    )


@dataclass(frozen=True)
class Binding:
    head: str
    base: Base

    def body(self) -> str:
        return _MARKER + json.dumps(
            {"head": self.head, "base": self.base.json()}, sort_keys=True
        )

    @classmethod
    def from_review(cls, review: dict[str, object]) -> Self:
        body = _string(review.get("body"), "approval_failed")
        _require(body.startswith(_MARKER), "approval_failed")
        try:
            data = _object(json.loads(body.removeprefix(_MARKER)), "approval_failed")
        except json.JSONDecodeError as error:
            msg = "approval_failed"
            raise RefusalError(msg) from error
        head = _sha(data.get("head"), "approval_failed")
        _require(review.get("commit_id") == head, "approval_failed")
        base = _object(data.get("base"), "approval_failed")
        return cls(
            head,
            Base(
                _integer(base.get("repository_id"), "approval_failed"),
                _string(base.get("ref"), "approval_failed"),
                _sha(base.get("merge_base"), "approval_failed"),
            ),
        )

    def change(self, session: Session, pull: Pull) -> str | None:
        if (
            pull.head != self.head
            or pull.head_repo.get("id") != session.trigger.repository_id
        ):
            return "head_moved"
        if (
            pull.base_repository_id != self.base.repository_id
            or pull.base_ref != self.base.ref
            or session.snapshot(pull) != self.base
        ):
            return "base_changed"
        return None


def _reviews(session: Session) -> dict[int, dict[str, object]]:
    path = f"{session.pull_path}/reviews"
    reviews: dict[int, dict[str, object]] = {}
    for review in session.api.pages(path):
        user = review.get("user")
        if (
            not isinstance(user, dict)
            or user.get("type") != "Bot"
            or user.get("login") != APPROVER
        ):
            continue
        review_id = _integer(review.get("id"), "approval_failed")
        _require(review_id not in reviews, "pagination_truncated")
        reviews[review_id] = review
    return reviews


def _effective(reviews: dict[int, dict[str, object]]) -> dict[str, object] | None:
    # GitHub returns reviews in chronological order. A comment or pending
    # review does not supersede an approval. A dismissal does.
    for review in reversed(reviews.values()):
        state = review.get("state")
        if state in ("APPROVED", "DISMISSED", "CHANGES_REQUESTED"):
            return review if state == "APPROVED" else None
        _require(state in ("COMMENTED", "PENDING"), "approval_failed")
    return None


def _dismiss(session: Session, review_id: int, code: str) -> Decision:
    path = f"{session.pull_path}/reviews/{review_id}/dismissals"
    try:
        result = session.api.request(path, method="PUT", body={"message": code})
        review = _object(result.body, "dismissal_failed")
        _require(
            review.get("id") == review_id and review.get("state") == "DISMISSED",
            "dismissal_failed",
        )
    except RefusalError:
        return refuse(code, "dismissal_failed")
    return refuse(code)


def _after_post(session: Session, binding: Binding, review_id: int) -> Decision:
    try:
        third = session.read_pull()
        change = binding.change(session, third)
    except RefusalError as error:
        # A review already exists. Attempt to remove it if the binding cannot
        # be confirmed, including when the API is unavailable.
        return _dismiss(session, review_id, error.code)
    if change is not None:
        return _dismiss(session, review_id, f"{change}_after_approval")
    if third.data.get("state") == "open" or third.data.get("merged") is True:
        return Decision("ok_pin_only", [])
    return _dismiss(session, review_id, "approval_failed")


def _reconcile(
    session: Session, seen: dict[int, dict[str, object]], binding: Binding
) -> int:
    try:
        reviews = _reviews(session)
        effective = _effective(reviews)
        _require(effective is not None, "approval_failed")
        review = _object(effective, "approval_failed")
        review_id = _integer(review.get("id"), "approval_failed")
        _require(
            review_id not in seen and Binding.from_review(review) == binding,
            "approval_failed",
        )
    except RefusalError as error:
        msg = "approval_failed"
        raise RefusalError(msg) from error
    return review_id


def _post(
    session: Session, binding: Binding, seen: dict[int, dict[str, object]]
) -> Decision:
    try:
        response = session.api.request(
            f"{session.pull_path}/reviews",
            method="POST",
            body={
                "event": "APPROVE",
                "commit_id": binding.head,
                "body": binding.body(),
            },
        )
    except APIError as error:
        if not error.ambiguous:
            return refuse("approval_failed")
        # GitHub may have accepted the write. A missing review is uncertain
        # because the list may lag. Never repeat an uncertain write.
        return _after_post(session, binding, _reconcile(session, seen, binding))
    try:
        review = _object(response.body, "approval_failed")
        review_id = _integer(review.get("id"), "approval_failed")
    except RefusalError:
        return _after_post(session, binding, _reconcile(session, seen, binding))
    _require(review_id not in seen, "approval_failed")
    if review.get("commit_id") != binding.head or review.get("state") != "APPROVED":
        return _dismiss(session, review_id, "approval_failed")
    return _after_post(session, binding, review_id)


def approve(  # noqa: PLR0911 - each early return ends the review protocol
    session: Session,
    initial: Pull,
    base: Base,
    decision: Decision,
    *,
    enforce: bool,
) -> Decision:
    if not decision.approve:
        return decision
    binding = Binding(session.trigger.head, base)
    seen = _reviews(session) if enforce else {}
    existing = _effective(seen)
    if existing is not None:
        previous = Binding.from_review(existing)
        change = previous.change(session, initial)
        if change is not None:
            return _dismiss(
                session,
                _integer(existing.get("id"), "approval_failed"),
                f"{change}_after_approval",
            )

    findings = _checks(checks_for(session, initial, base))
    if findings:
        return Decision(findings[0].code, findings)
    second = session.read_pull()
    change = binding.change(session, second)
    if change is not None:
        if existing is not None:
            return _dismiss(
                session,
                _integer(existing.get("id"), "approval_failed"),
                f"{change}_after_approval",
            )
        return refuse(change)
    _require(second.head_ref == initial.head_ref, "head_moved")
    _require(second.base_repo.get("default_branch") == base.ref, "base_changed")
    second.shape(config_from({"config": session.config}).opt_out_label)
    if not enforce:
        return decision
    if existing is not None:
        return refuse("already_approved")
    return _post(session, binding, seen)
