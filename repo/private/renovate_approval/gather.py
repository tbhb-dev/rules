# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Gather GitHub evidence and read pull request changes from Git objects."""

import base64
import hashlib
import http.client
import ipaddress
import json
import os
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable, Mapping  # noqa: TC003 - Python 3.11
from contextlib import suppress
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from http import HTTPStatus
from pathlib import Path
from typing import IO, TYPE_CHECKING, Protocol, Self, cast
from urllib.parse import parse_qs, quote, urlsplit

from .decide import MAX_DIFF_BYTES, _pull_request
from .matcher import (
    _MISE_ASSET,
    _REMOTE,
    _REPOSITORY,
    _USES,
    Change,
    RefusalError,
    _destination,
    _file_headers,
    _hunks,
    _kind,
    _mise_lock_source,
    _object,
    _patch_sections,
    _platforms,
    _require,
    _star_calls,
    _star_fields,
    _string,
    _toml,
    _url_version,
    config_from,
    objects,
    positive_id,
)
from .versions import COMMIT

if TYPE_CHECKING:
    import ssl

# cspell:ignore newurl textconv
API = "https://api.github.com"
APPROVER = "tbhb-dev-pin-approver[bot]"
APPROVER_JOB = "approve"
PER_PAGE = 100
MAX_FILES = 500
BYTES_PER_MEGABYTE = 1024 * 1024
API_LIMIT = 16 * BYTES_PER_MEGABYTE
GIT_TEXT_LIMIT = 16 * BYTES_PER_MEGABYTE
HTTP_TIMEOUT = 15
GIT_TIMEOUT = 90
_REPO_NAME = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_NEXT = re.compile(r'<([^<>]+)>;\s*rel="next"')
_CHECK = re.compile(r"/check-runs/([1-9][0-9]*)")
_RAW = re.compile(
    rb":([0-7]{6}) ([0-7]{6}) ([a-f0-9]{40}) ([a-f0-9]{40}) ([A-Z][0-9]*)"
)
_BLOB_MODES = {"100644", "100755"}
_TAG_DEPTH = 8
_NETWORK_ERRORS = (OSError, http.client.HTTPException)
_DOWNLOAD_ERRORS = (*_NETWORK_ERRORS, ValueError)
_FACT_ERRORS = (RefusalError, KeyError, IndexError)


class APIError(RefusalError):
    def __init__(self, code: str, *, ambiguous: bool = False) -> None:
        super().__init__(code)
        self.ambiguous = ambiguous


class _Redirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, validate: Callable[[str], None] | None = None) -> None:
        self.validate = validate

    def redirect_request(  # noqa: PLR0913, PLR0917  # pyrefly: ignore [missing-override-decorator]
        self,
        req: urllib.request.Request,
        fp: IO[bytes],
        code: int,
        msg: str,
        headers: http.client.HTTPMessage,
        newurl: str,
    ) -> urllib.request.Request | None:
        if self.validate is None:
            return None
        self.validate(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


@dataclass(frozen=True)
class Response:
    body: object
    headers: Mapping[str, str] = field(default_factory=dict)


class Transport(Protocol):
    def __call__(self, request: urllib.request.Request) -> Response: ...


def http_json(request: urllib.request.Request) -> Response:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _Redirect())
    with opener.open(request, timeout=HTTP_TIMEOUT) as response:
        body = response.read(API_LIMIT + 1)
        if len(body) > API_LIMIT:
            msg = "GitHub response exceeds size limit"
            raise ValueError(msg)
        return Response(json.loads(body), dict(response.headers.items()))


def _header(headers: Mapping[str, str], name: str) -> str | None:
    return next((value for key, value in headers.items() if key.lower() == name), None)


class GitHub:
    def __init__(
        self,
        token: str,
        transport: Transport = http_json,
        pause: Callable[[float], None] = time.sleep,
    ) -> None:
        self.token = token
        self.transport = transport
        self.pause = pause
        self.repository_id: int | None = None

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: dict[str, object] | None = None,
        public: bool = False,
    ) -> Response:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "renovate-auto-approval",
        }
        if self.token and not public:
            headers["Authorization"] = f"Bearer {self.token}"
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(  # noqa: S310 - fixed HTTPS API origin
            API + path,
            data=None if body is None else json.dumps(body).encode(),
            headers=headers,
            method=method,
        )
        retries = 2 if method == "GET" else 0
        for attempt in range(retries + 1):
            try:
                return self.transport(request)
            except urllib.error.HTTPError as error:
                with error:
                    if error.code == HTTPStatus.TOO_MANY_REQUESTS or (
                        error.code == HTTPStatus.FORBIDDEN
                        and (
                            error.headers.get("X-RateLimit-Remaining") == "0"
                            or "Retry-After" in error.headers
                        )
                    ):
                        msg = "rate_limited"
                        raise APIError(msg) from error
                    if not 500 <= error.code <= 599:  # noqa: PLR2004 - HTTP status class
                        msg = "api_error"
                        raise APIError(msg) from error
            except _NETWORK_ERRORS:
                pass
            except ValueError as error:
                msg = "api_error"
                raise APIError(msg, ambiguous=method == "POST") from error
            if attempt < retries:
                self.pause(2**attempt)
        msg = "api_error"
        raise APIError(msg, ambiguous=method == "POST")

    def get(self, path: str, *, public: bool = False) -> dict[str, object]:
        return _object(self.request(path, public=public).body, "api_error")

    def pages(
        self,
        path: str,
        *,
        items: str | None = None,
        total: int | None = None,
        count_key: str = "total_count",
        public: bool = False,
    ) -> list[dict[str, object]]:
        results: list[dict[str, object]] = []
        page = 1
        while True:
            url = f"{path}?per_page={PER_PAGE}&page={page}"
            response = self.request(url, public=public)
            data = response.body
            if items is not None:
                envelope = _object(data, "pagination_truncated")
                reported = envelope.get(count_key)
                _require(
                    type(reported) is int
                    and reported >= 0
                    and (total is None or total == reported),
                    "pagination_truncated",
                )
                total = cast("int", reported)
                data = envelope.get(items)
            batch = objects(data, "pagination_truncated")
            results.extend(batch)
            link = _header(response.headers, "link") or ""
            expected = f"{API}{path}?per_page={PER_PAGE}&page={page + 1}"
            if not _NEXT.search(link):
                _require(total is None or len(results) == total, "pagination_truncated")
                return results
            _require(
                len(batch) == PER_PAGE and (total is None or len(results) < total),
                "pagination_truncated",
            )
            next_links = _NEXT.findall(link)
            _require(
                len(next_links) == 1
                and _same_page(next_links[0], expected, self.repository_id),
                "pagination_truncated",
            )
            page += 1


def _same_page(actual: str, expected: str, repository_id: int | None) -> bool:
    left, right = urlsplit(actual), urlsplit(expected)
    suffix = right.path.split("/", 4)[-1]
    numeric = f"/repositories/{repository_id}/{suffix}"
    return (
        left.scheme == right.scheme
        and left.netloc == right.netloc
        and left.path in (right.path, numeric)
        and not left.fragment
        and parse_qs(left.query) == parse_qs(right.query)
    )


def _sha(value: object, code: str = "api_error") -> str:
    text = _string(value, code)
    _require(COMMIT.fullmatch(text), code)
    return text


def _integer(value: object, code: str = "api_error") -> int:
    _require(positive_id(value), code)
    return cast("int", value)


def _count(value: object) -> int:
    _require(type(value) is int and value >= 0, "pagination_truncated")
    return cast("int", value)


def _repo_path(repository: str) -> str:
    _require(
        _REPO_NAME.fullmatch(repository)
        and not {".", ".."}.intersection(repository.split("/")),
        "api_error",
    )
    return f"/repos/{repository}"


@dataclass(frozen=True)
class Trigger:
    repository: str
    repository_id: int
    head: str
    head_repository_id: int
    run_id: int
    attempt: int
    workflow_id: int

    @classmethod
    def read(cls, repository: str, event: object) -> Self:
        _repo_path(repository)
        payload = _object(event, "api_error")
        run = _object(payload.get("workflow_run"), "api_error")
        repo = _object(payload.get("repository"), "api_error")
        head_repo = _object(run.get("head_repository"), "fork_head")
        _require(repo.get("full_name") == repository, "api_error")
        _require(
            payload.get("action") == "completed" and run.get("event") == "pull_request",
            "check_missing",
        )
        return cls(
            repository,
            _integer(repo.get("id")),
            _sha(run.get("head_sha")),
            _integer(head_repo.get("id")),
            _integer(run.get("id")),
            _integer(run.get("run_attempt")),
            _integer(run.get("workflow_id")),
        )


@dataclass(frozen=True)
class Base:
    repository_id: int
    ref: str
    merge_base: str

    def json(self) -> dict[str, object]:
        return asdict(self)


@dataclass
class Pull:
    data: dict[str, object]
    head: str
    head_ref: str
    base_sha: str
    base_repository_id: int
    base_ref: str
    head_repo: dict[str, object]
    base_repo: dict[str, object]
    labels: list[str]

    @classmethod
    def read(cls, data: dict[str, object]) -> Self:
        head = _object(data.get("head"), "api_error")
        base = _object(data.get("base"), "api_error")
        base_repo = _object(base.get("repo"), "api_error")
        return cls(
            data,
            _sha(head.get("sha")),
            _string(head.get("ref"), "api_error"),
            _sha(base.get("sha")),
            _integer(base_repo.get("id")),
            _string(base.get("ref"), "api_error"),
            _object(head.get("repo"), "fork_head"),
            base_repo,
            [
                _string(label.get("name"), "api_error")
                for label in objects(data.get("labels"), "api_error")
            ],
        )

    def shape(self, opt_out_label: str) -> None:
        _require(self.data.get("state") == "open", "pr_not_open")
        _require(self.data.get("draft") is False, "pr_draft")
        _require(opt_out_label not in self.labels, "opted_out")


class GitRunner(Protocol):
    def __call__(
        self, cwd: Path, args: tuple[str, ...], env: Mapping[str, str], limit: int
    ) -> bytes: ...


def run_git(
    cwd: Path, args: tuple[str, ...], env: Mapping[str, str], limit: int
) -> bytes:
    # Isolate Git from checkout configuration and keep stderr out of logs.
    with tempfile.TemporaryFile() as output:
        try:
            subprocess.run(  # noqa: S603 - fixed Git command, no shell
                ("git", *args),  # noqa: S607 - used on the hosted runner
                cwd=cwd,
                env=env,
                stdout=output,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=GIT_TIMEOUT,
            )
        except (OSError, subprocess.SubprocessError) as error:
            msg = "diff_unavailable"
            raise RefusalError(msg) from error
        output.seek(0)
        return output.read(limit + 1)


@dataclass(frozen=True)
class GitDiff:
    patch: bytes
    modes: dict[str, object]
    texts: dict[str, object]
    has_mise_lock: bool


@dataclass(frozen=True)
class RawFile:
    path: str
    old_mode: str
    new_mode: str
    old_object: str
    new_object: str


def _raw_files(raw: bytes) -> Iterable[RawFile]:
    records = raw.split(b"\0")
    _require(not records.pop(), "diff_unavailable")
    fields = iter(records)
    for header in fields:
        entry = _RAW.fullmatch(header)
        _require(entry is not None, "diff_unavailable")
        entry = cast("re.Match[bytes]", entry)
        if entry[5].startswith((b"R", b"C")):
            next(fields, b"")  # The destination follows the source.
        path = next(fields, b"")
        _require(path, "diff_unavailable")
        try:
            yield RawFile(
                path.decode(), *(part.decode() for part in entry.groups()[:4])
            )
        except UnicodeError as error:
            msg = "encoding"
            raise RefusalError(msg) from error


def git_diff(
    session: "Session",  # noqa: UP037 - Python 3.11 evaluates annotations
    head: str,
    merge_base: str,
    files: list[str],
    runner: GitRunner,
) -> GitDiff:
    with tempfile.TemporaryDirectory(prefix="renovate-approval-") as directory:
        cwd = Path(directory)
        remote = f"https://github.com{session.path.removeprefix('/repos')}.git"
        options = {
            "http.followRedirects": "false",
            "core.quotePath": "true",
            "protocol.allow": "never",
            "protocol.https.allow": "always",
        }
        if session.api.token:
            auth = base64.b64encode(
                f"x-access-token:{session.api.token}".encode()
            ).decode()
            options["http.https://github.com/.extraheader"] = (
                f"Authorization: Basic {auth}"
            )
        env = {
            "PATH": os.defpath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_COUNT": str(len(options)),
        }
        for index, (key, value) in enumerate(options.items()):
            env[f"GIT_CONFIG_KEY_{index}"] = key
            env[f"GIT_CONFIG_VALUE_{index}"] = value
        runner(cwd, ("init", "--bare", "--template="), env, MAX_DIFF_BYTES)
        runner(cwd, ("remote", "add", "origin", remote), env, MAX_DIFF_BYTES)
        runner(
            cwd,
            (
                "fetch",
                "--no-tags",
                "--depth=1",
                "--filter=blob:none",
                "origin",
                merge_base,
                head,
            ),
            env,
            MAX_DIFF_BYTES,
        )
        return _git_objects(cwd, (merge_base, head), files, env, runner)


def _git_objects(
    cwd: Path,
    revisions: tuple[str, str],
    files: list[str],
    env: Mapping[str, str],
    runner: GitRunner,
) -> GitDiff:
    commands = (
        "diff",
        "--find-renames",
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
    )
    raw = runner(
        cwd, (*commands, "--raw", "-z", "--no-abbrev", *revisions), env, MAX_DIFF_BYTES
    )
    _require(len(raw) <= MAX_DIFF_BYTES, "diff_too_large")
    entries = list(_raw_files(raw))
    paths = {entry.path for entry in entries}
    _require(
        len(paths) == len(entries) == len(files) and paths == set(files),
        "file_list_mismatch",
    )
    modes: dict[str, object] = {}
    texts: dict[str, object] = {}
    remaining = GIT_TEXT_LIMIT
    for entry in entries:
        modes[entry.path] = [entry.old_mode, entry.new_mode]
        if entry.old_mode in _BLOB_MODES and entry.new_mode in _BLOB_MODES:
            base, head, remaining = _read_blobs(cwd, entry, env, runner, remaining)
            texts[entry.path] = {"base": base, "head": head}
    patch = runner(cwd, (*commands, "--unified=0", *revisions), env, MAX_DIFF_BYTES)
    _require(len(patch) <= MAX_DIFF_BYTES, "diff_too_large")
    tree = runner(
        cwd, ("ls-tree", "-z", revisions[0], "--", "mise.lock"), env, MAX_DIFF_BYTES
    )
    return GitDiff(patch, modes, texts, bool(tree))


def _read_blobs(
    cwd: Path, entry: RawFile, env: Mapping[str, str], runner: GitRunner, remaining: int
) -> tuple[str, str, int]:
    texts = []
    for oid in (entry.old_object, entry.new_object):
        size = runner(cwd, ("cat-file", "-s", oid), env, 32).strip()
        _require(size.isdigit(), "diff_unavailable")
        _require(int(size) <= remaining, "diff_too_large")
        content = runner(cwd, ("cat-file", "blob", oid), env, remaining)
        _require(len(content) == int(size), "diff_unavailable")
        remaining -= len(content)
        # Binary patches are rejected before the matcher consumes file text.
        texts.append(content.decode(errors="replace"))
    return texts[0], texts[1], remaining


@dataclass
class Session:
    api: GitHub
    trigger: Trigger
    config: dict[str, object]
    workflows: dict[str, int]
    max_download_bytes: int
    number: int | None = None
    base: Base | None = None
    read_times: list[str] = field(default_factory=list)

    @property
    def path(self) -> str:
        return _repo_path(self.trigger.repository)

    @property
    def pull_path(self) -> str:
        return f"{self.path}/pulls/{self.number}"

    def read_pull(self) -> Pull:
        self.read_times.append(datetime.now(UTC).isoformat())
        data = self.api.get(self.pull_path)
        _require(data.get("number") == self.number, "api_error")
        return Pull.read(data)

    def compare(self, base: str, head: str) -> str:
        compare = self.api.get(f"{self.path}/compare/{base}...{head}")
        merge_base = _object(compare.get("merge_base_commit"), "api_error")
        return _sha(merge_base.get("sha"))

    def snapshot(self, pull: Pull) -> Base:
        return Base(
            pull.base_repository_id,
            pull.base_ref,
            self.compare(pull.base_sha, pull.head),
        )

    def initial(self) -> Pull:
        trigger = self.trigger
        _require(trigger.repository_id == trigger.head_repository_id, "fork_head")
        associated = self.api.pages(f"{self.path}/commits/{trigger.head}/pulls")
        opened = [pr for pr in associated if pr.get("state") == "open"]
        _require(len(opened) == 1, "pr_not_unique")
        head = _object(opened[0].get("head"), "api_error")
        repo = _object(head.get("repo"), "fork_head")
        _require(
            repo.get("id") == trigger.repository_id
            and repo.get("full_name") == trigger.repository,
            "fork_head",
        )
        _require(head.get("sha") == trigger.head, "head_mismatch_at_start")
        self.number = _integer(opened[0].get("number"))
        pull = self.read_pull()
        _require(pull.head == trigger.head, "head_mismatch_at_start")
        _require(
            pull.head_repo.get("id") == trigger.repository_id
            and pull.head_repo.get("full_name") == trigger.repository,
            "fork_head",
        )
        _require(
            pull.base_repository_id == trigger.repository_id
            and pull.base_repo.get("full_name") == trigger.repository
            and pull.base_ref == pull.base_repo.get("default_branch"),
            "base_not_default",
        )
        config = config_from({"config": self.config})
        pull.shape(config.opt_out_label)
        count = _count(pull.data.get("changed_files"))
        _require(count < MAX_FILES and count <= config.max_files, "too_many_files")
        self.base = self.snapshot(pull)
        return pull

    def metadata(self, pull: Pull, base: Base) -> dict[str, object]:
        options = config_from({"config": self.config})
        count = _count(pull.data.get("changed_files"))
        count_commits = _count(pull.data.get("commits"))
        _require(count_commits <= options.max_commits, "too_many_commits")
        user = _object(pull.data.get("user"), "author_not_renovate")
        issue = self.api.get(f"{self.path}/issues/{self.number}")
        actor = issue.get("performed_via_github_app")
        app_id = (
            None
            if actor is None
            else _object(actor, "author_app_mismatch").get("id", 0)
        )
        commits = self.api.pages(f"{self.pull_path}/commits", total=count_commits)
        pinned = self.api.pages(
            f"{self.path}/compare/{base.merge_base}...{pull.head}",
            items="commits",
            total=count_commits,
            count_key="total_commits",
        )
        _require(
            [item.get("sha") for item in commits]
            == [item.get("sha") for item in pinned]
            and bool(pinned)
            and pinned[-1].get("sha") == pull.head,
            "commit_not_renovate",
        )
        metadata: dict[str, object] = {
            "pr_count": 1,
            "state": pull.data.get("state"),
            "draft": pull.data.get("draft"),
            "base_ref": pull.base_ref,
            "default_branch": pull.base_repo.get("default_branch"),
            "base_repo": pull.base_repo.get("full_name"),
            "head_repo": pull.head_repo.get("full_name"),
            "labels": pull.labels,
            "author": {key: user.get(key) for key in ("id", "login", "type")},
            "author_app_id": app_id,
            "commits": [_commit_fields(commit) for commit in pinned],
            "config": self.config,
        }
        findings = _pull_request(metadata)
        if findings:
            raise RefusalError(findings[0].code)
        metadata["files"] = [
            _string(item.get("filename"), "file_list_mismatch")
            for item in self.api.pages(f"{self.pull_path}/files", total=count)
        ]
        return metadata


def _commit_fields(commit: dict[str, object]) -> dict[str, object]:
    signed = _object(commit.get("commit"), "signature_unverified")
    verification = _object(signed.get("verification"), "signature_unverified")
    return {
        "author_id": _object(commit.get("author"), "commit_not_renovate").get("id"),
        "committer": _object(commit.get("committer"), "commit_not_renovate").get(
            "login"
        ),
        "verified": verification.get("verified"),
    }


def _branch_rules(
    session: Session, base: Base
) -> tuple[list[dict[str, object]], dict[str, object]]:
    path = f"{session.path}/rules/branches/{quote(base.ref, safe='')}"
    required = []
    review: dict[str, object] = {}
    for rule in session.api.pages(path):
        kind = rule.get("type")
        if kind == "required_status_checks":
            parameters = _object(rule.get("parameters"), "required_check_unbound")
            for check in objects(
                parameters.get("required_status_checks"), "required_check_unbound"
            ):
                name = _string(check.get("context"), "required_check_unbound")
                required.append(
                    {
                        "name": name,
                        "app_id": check.get("integration_id"),
                        "workflow_id": session.workflows.get(name),
                    }
                )
        elif kind == "pull_request":
            parameters = _object(rule.get("parameters"), "stale_dismissal_off")
            if (
                positive_id(parameters.get("required_approving_review_count"))
                and parameters.get("dismiss_stale_reviews_on_push") is True
                and parameters.get("require_last_push_approval") is True
            ):
                review = parameters
    return required, review


def checks_for(session: Session, pull: Pull, base: Base) -> dict[str, object]:
    required, review = _branch_rules(session, base)
    # Reusable jobs can appear as "<caller job> / approve" in rulesets.
    approver = next(
        (
            name
            for rule in required
            if (name := str(rule["name"])).split(" / ")[-1] == APPROVER_JOB
        ),
        APPROVER_JOB,
    )
    _require(
        not any(rule["name"] == approver for rule in required), "self_check_required"
    )
    checks: dict[str, object] = {
        "required": required,
        "rules": review,
        "approver_check": approver,
        "snapshot": {},
        "runs": [],
    }
    if required and all(
        positive_id(rule["app_id"])
        and rule["workflow_id"] == session.trigger.workflow_id
        for rule in required
    ):
        try:
            snapshot, runs = _run_checks(session, pull, base, required)
        except RefusalError as error:
            if error.code != "check_missing":
                raise
        else:
            checks["snapshot"], checks["runs"] = snapshot, runs
    return checks


def _run_checks(
    session: Session, pull: Pull, base: Base, required: list[dict[str, object]]
) -> tuple[dict[str, object], list[dict[str, object]]]:
    trigger = session.trigger
    path = f"{session.path}/actions/runs/{trigger.run_id}"
    run = session.api.get(path, public=True)
    repo = _object(run.get("head_repository"), "check_missing")
    _require(
        run.get("id") == trigger.run_id
        and run.get("run_attempt") == trigger.attempt
        and run.get("workflow_id") == trigger.workflow_id
        and run.get("head_sha") == trigger.head
        and run.get("event") == "pull_request"
        and repo.get("id") == trigger.repository_id,
        "check_missing",
    )
    _verify_association(session, pull, base, run)
    suite_id = _integer(run.get("check_suite_id"), "check_missing")
    suite = session.api.get(f"{session.path}/check-suites/{suite_id}")
    _require(suite.get("id") == suite_id, "check_missing")
    suite_head = _sha(suite.get("head_sha"), "check_missing")
    if suite_head != trigger.head:
        _verify_test_merge(session, suite_head, run)
    snapshot: dict[str, object] = {
        "run_id": trigger.run_id,
        "attempt": trigger.attempt,
        "workflow_id": trigger.workflow_id,
        "suite_id": suite_id,
    }
    jobs = session.api.pages(
        f"{path}/attempts/{trigger.attempt}/jobs", items="jobs", public=True
    )
    names = {rule["name"] for rule in required}
    runs = [
        _read_check(session, job, suite_head, snapshot)
        for job in jobs
        if job.get("name") in names
    ]
    return snapshot, runs


def _verify_association(
    session: Session, pull: Pull, base: Base, run: dict[str, object]
) -> None:
    pulls = objects(run.get("pull_requests"), "check_missing")
    _require(len(pulls) == 1, "check_missing")
    target = pulls[0]
    head = _object(target.get("head"), "check_missing")
    ci_base = _object(target.get("base"), "check_missing")
    repo = _object(ci_base.get("repo"), "check_missing")
    head_repo = _object(head.get("repo"), "check_missing")
    _require(
        target.get("number") == session.number
        and head.get("ref") == pull.head_ref
        and head.get("sha") == pull.head
        and head_repo.get("id") == session.trigger.repository_id
        and ci_base.get("ref") == base.ref
        and repo.get("id") == base.repository_id,
        "check_missing",
    )
    base_sha = _sha(ci_base.get("sha"), "check_missing")
    _require(
        base_sha == pull.base_sha
        or session.compare(base_sha, pull.head) == base.merge_base,
        "check_missing",
    )


def _verify_test_merge(
    session: Session, suite_head: str, run: dict[str, object]
) -> None:
    target = objects(run.get("pull_requests"), "check_missing")[0]
    base = _object(target.get("base"), "check_missing")
    commit = session.api.get(f"{session.path}/commits/{suite_head}")
    parents = objects(commit.get("parents"), "check_missing")
    _require(
        commit.get("sha") == suite_head
        and [parent.get("sha") for parent in parents]
        == [base.get("sha"), session.trigger.head],
        "check_missing",
    )


def _read_check(
    session: Session,
    job: dict[str, object],
    suite_head: str,
    snapshot: dict[str, object],
) -> dict[str, object]:
    trigger = session.trigger
    link = _string(job.get("check_run_url"), "check_missing")
    match = _CHECK.fullmatch(link.removeprefix(API + session.path))
    _require(
        link.startswith(API + session.path + "/")
        and match is not None
        and job.get("run_id") == trigger.run_id
        and job.get("run_attempt") == trigger.attempt
        and job.get("head_sha") in (trigger.head, suite_head),
        "check_missing",
    )
    match = cast("re.Match[str]", match)
    check = session.api.get(f"{session.path}/check-runs/{match[1]}")
    suite = _object(check.get("check_suite"), "check_missing")
    app = _object(check.get("app"), "check_missing")
    _require(
        check.get("id") == int(match[1])
        and suite.get("id") == snapshot["suite_id"]
        and check.get("head_sha") == suite_head
        and check.get("name") == job.get("name"),
        "check_missing",
    )
    return {
        **snapshot,
        "name": check["name"],
        "app_id": app.get("id"),
        "status": check.get("status"),
        "conclusion": check.get("conclusion"),
    }


def _public_address(value: str) -> bool:
    address = ipaddress.ip_address(value.split("%", 1)[0])
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    return address.is_global and not address.is_multicast and not address.is_reserved


def _connect_public(
    address: tuple[str, int], timeout: float, *_args: object
) -> socket.socket:
    host, port = address
    addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    # Resolve once and connect to the verified numeric address to prevent rebinding.
    _require(
        addresses and all(_public_address(str(item[4][0])) for item in addresses),
        "digest_unverifiable",
    )
    for family, kind, protocol, _, target in addresses:
        connection = socket.socket(family, kind, protocol)
        try:
            connection.settimeout(timeout)
            connection.connect(target)
        except OSError:
            connection.close()
        else:
            return connection
    msg = "artifact host unreachable"
    raise OSError(msg)


class _PublicConnection(http.client.HTTPSConnection):
    def __init__(self, host: str, **kwargs: object) -> None:
        super().__init__(
            host,
            timeout=HTTP_TIMEOUT,
            context=cast("ssl.SSLContext | None", kwargs.get("context")),
        )
        self._create_connection = _connect_public


class _PublicHTTPS(urllib.request.HTTPSHandler):
    def https_open(  # pyrefly: ignore [missing-override-decorator]
        self, req: urllib.request.Request
    ) -> http.client.HTTPResponse:
        _public_url(req.full_url)
        return self.do_open(_PublicConnection, req, context=None)


def _public_url(url: str) -> None:
    parsed = urlsplit(url)
    _require(
        parsed.scheme == "https"
        and parsed.hostname
        and parsed.username is None
        and parsed.password is None
        and parsed.port in (None, 443),
        "digest_unverifiable",
    )


def download_digest(url: str, limit: int) -> str | None:
    try:
        _public_url(url)
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _PublicHTTPS(), _Redirect(_public_url)
        )
        digest = hashlib.sha256()
        with opener.open(url, timeout=HTTP_TIMEOUT) as response:
            remaining = limit
            for chunk in iter(lambda: response.read(min(65536, limit + 1)), b""):
                remaining -= len(chunk)
                if remaining < 0:
                    return None
                digest.update(chunk)
        return digest.hexdigest()
    except _DOWNLOAD_ERRORS:
        return None


class Facts:
    def __init__(
        self, api: GitHub, download: Callable[[str, int], str | None], limit: int
    ) -> None:
        self.api = api
        self.download = download
        self.limit = limit
        self.cache: dict[tuple[str, str], dict[str, object]] = {}
        self.digests: dict[str, str | None] = {}

    def _get(self, repo: str, path: str) -> dict[str, object]:
        key = repo, path
        if key not in self.cache:
            url = f"{_repo_path(repo)}{path}"
            try:
                self.cache[key] = self.api.get(url, public=True)
            except RefusalError:
                # The matcher reports missing public evidence at the pin.
                self.cache[key] = {}
        return self.cache[key]

    def tag(self, repo: str, name: str) -> dict[str, object]:
        ref = self._get(repo, f"/git/ref/tags/{quote(name, safe='')}")
        for _ in range(_TAG_DEPTH):
            target = _object(ref.get("object"), "fact_missing")
            sha = _sha(target.get("sha"), "fact_missing")
            if target.get("type") == "commit":
                return {"repo": repo, "name": name, "commit": sha}
            _require(target.get("type") == "tag", "fact_missing")
            ref = self._get(repo, f"/git/tags/{sha}")
        return {}

    def ancestry(
        self, repo: str, old: str, new: str, *, branch: bool
    ) -> dict[str, object]:
        source = self._get(repo, "")
        default = _string(source.get("default_branch"), "fact_missing")
        ref = self._get(repo, f"/git/ref/heads/{quote(default, safe='')}")
        target = _object(ref.get("object"), "fact_missing")
        tip = _sha(target.get("sha"), "fact_missing")
        return {
            "repo": repo,
            "old": old,
            "new": new,
            "merged_at_source": self._ancestor(repo, new, tip),
            "old_is_ancestor": self._ancestor(repo, old, new) if branch else None,
        }

    def _ancestor(self, repo: str, old: str, new: str) -> bool | None:
        status = self._get(repo, f"/compare/{old}...{new}").get("status")
        if status in ("ahead", "identical"):
            return True
        if status in ("behind", "diverged"):
            return False
        return None

    def artifact(self, url: str) -> dict[str, object]:
        if url not in self.digests:
            self.digests[url] = self.download(url, self.limit)
        return {"url": url, "sha256": self.digests[url]}

    def asset(self, url: str) -> dict[str, object]:
        repo, endpoint = url.removeprefix(API + "/repos/").split("/releases/", 1)
        asset = self._get(repo, f"/releases/{endpoint}")
        return {
            "url_api": url,
            **{key: asset[key] for key in ("browser_download_url",) if key in asset},
        }


def _workflow_facts(
    evidence: Facts, before: str, after: str, owners: frozenset[str]
) -> dict[str, object]:
    old, new = _USES.fullmatch(before), _USES.fullmatch(after)
    _require(old and new, "fact_missing")
    old, new = cast("re.Match[str]", old), cast("re.Match[str]", new)
    repo, version = new["repo"], new["version"]
    result: dict[str, object] = {}
    branch = version == "main"
    if not branch:
        result["tag"] = evidence.tag(repo, version)
    if repo.split("/")[0].lower() in owners:
        with suppress(RefusalError):
            result["ancestry"] = evidence.ancestry(
                repo, old["commit"], new["commit"], branch=branch
            )
    return result


def _starlark_facts(
    evidence: Facts, base: str, head: str, pairs: Iterable[tuple[int, int]]
) -> dict[str, object]:
    before, after = _star_calls(base), _star_calls(head)
    result: dict[str, object] = {}
    for old_line, new_line in pairs:
        try:
            old, new = before[old_line], after[new_line]
            _, left = _star_fields(old, old_line)
            _, right = _star_fields(new, new_line)
            if new.name == "git_override":
                remote = _REMOTE.fullmatch(right["remote"].value.removesuffix(".git"))
                _require(remote is not None, "fact_missing")
                repo = cast("re.Match[str]", remote)[1]
                result[str(new_line)] = {
                    "ancestry": evidence.ancestry(
                        repo,
                        left["commit"].value,
                        right["commit"].value,
                        branch=True,
                    )
                }
                continue
            key = "url" if "url" in right else "urls"
            url = right[key]
            change = _url_version(left[key].value, url.value)
            result[str(url.line)] = _archive_facts(evidence, url.value, change)
        except _FACT_ERRORS:
            continue
    return result


def _archive_facts(evidence: Facts, url: str, change: Change) -> dict[str, object]:
    result: dict[str, object] = {}
    if COMMIT.fullmatch(change.old) and COMMIT.fullmatch(change.new):
        match = _REPOSITORY.fullmatch(url)
        _require(match is not None, "fact_missing")
        repo = cast("re.Match[str]", match)[1]
        result["ancestry"] = evidence.ancestry(
            repo, change.old, change.new, branch=True
        )
    result["download"] = evidence.artifact(url)
    return result


def _mise_facts(evidence: Facts, base: str, head: str) -> dict[str, object]:
    spans = _mise_lock_source(head)
    previous = _object(_toml(base).get("tools"))
    current = _object(_toml(head).get("tools"))
    result: dict[str, object] = {}
    for tool, entries in current.items():
        old = objects(previous.get(tool), "fact_missing")
        for index, entry in enumerate(objects(entries)):
            _, before = _platforms(old[index])
            _, after = _platforms(entry)
            for platform, value in after.items():
                fields = _object(value)
                url = _string(fields.get("url"), "fact_missing")
                if url == _object(before.get(platform)).get("url"):
                    continue
                line = spans[tool, index, platform, "url"].start
                records = {"download": evidence.artifact(url)}
                asset = fields.get("url_api")
                if isinstance(asset, str) and _MISE_ASSET.fullmatch(asset):
                    records["asset"] = evidence.asset(asset)
                result[str(line)] = records
    return result


def pin_facts(
    patch: str,
    metadata: dict[str, object],
    needed: dict[str, set[int]],
    evidence: Facts,
) -> dict[str, object]:
    config = config_from(metadata)
    texts = _object(metadata["texts"])
    result: dict[str, object] = {}
    for section in _patch_sections(patch):
        path = _destination(section)
        if path not in needed:
            continue
        try:
            kind = _kind(path, config)
            text = _object(texts[path])
            base, head = _string(text["base"]), _string(text["head"])
            if kind == "mise_lock":
                result[path] = _mise_facts(evidence, base, head)
                continue
            pairs = [
                pair
                for hunk in _hunks(
                    _file_headers(path, section[1:], _object(metadata["modes"]))
                )
                if len(hunk.removed) == len(hunk.added)
                for pair in hunk.pairs()
                if pair[1] in needed[path]
            ]
            if kind == "starlark":
                result[path] = _starlark_facts(evidence, base, head, pairs)
            else:
                before, after = base.split("\n"), head.split("\n")
                records: dict[str, object] = {}
                for old, new in pairs:
                    try:
                        records[str(new)] = _workflow_facts(
                            evidence,
                            before[old - 1],
                            after[new - 1],
                            config.owners,
                        )
                    except RefusalError:
                        continue
                result[path] = records
        except _FACT_ERRORS:
            continue
    return result
