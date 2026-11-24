# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import hashlib
import http.client
import io
import json
import socket
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.request
from collections import Counter
from collections.abc import Mapping  # noqa: TC003 - the Bazel test runner evaluates annotations
from email.message import Message
from pathlib import Path
from typing import ClassVar, NamedTuple, cast
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

from repo.private.renovate_approval.__main__ import main
from repo.private.renovate_approval.gather import (
    API,
    API_LIMIT,
    BYTES_PER_MEGABYTE,
    GIT_TEXT_LIMIT,
    Facts,
    GitHub,
    Session,
    Trigger,
    _connect_public,
    _PublicConnection,
    _PublicHTTPS,
    _Redirect,
    download_digest,
    git_diff,
    http_json,
    pin_facts,
    run_git,
)
from repo.private.renovate_approval.gather import Response as Reply
from repo.private.renovate_approval.matcher import RefusalError

TESTDATA = Path(__file__).with_name("testdata")
API_DATA = Path(__file__).with_name("testdata_api")
BASELINE = API_DATA / "baseline"
HEAD = "c" * 40
BASE = "e" * 40
REPOSITORY = "example/project"


class FixtureResult(NamedTuple):
    report: dict[str, object]
    summary: str
    outputs: str


def load(path: Path) -> dict[str, object]:
    return cast("dict[str, object]", json.loads(path.read_bytes()))


# Tests use the flexible JSON shape of recorded HTTP responses.
Case = dict[str, object]


def cases(group: str) -> dict[str, Case]:
    result = {}
    for directory in sorted(API_DATA.iterdir()):
        if directory != BASELINE:
            case = load(directory / "case.json")
            if case["group"] == group:
                result[directory.name] = case
    return result


class Replay:
    def __init__(self, case: Case) -> None:
        self.case = case
        baseline = load(BASELINE / "responses.json")
        routes = cast("dict[str, tuple[str, dict[str, object]]]", baseline["routes"])
        overrides = cast(
            "dict[str, list[dict[str, object]]]", case.get("overrides", {})
        )
        self.routes = {
            route: overrides.get(name, [reply])
            for name, (route, reply) in routes.items()
        }
        self.routes.update(
            cast("dict[str, list[dict[str, object]]]", case.get("extra", {}))
        )
        self.calls: Counter[str] = Counter()
        self.waits: list[float] = []
        self.posted: list[dict[str, object]] = []
        self.unexpected: list[str] = []
        self.git_calls: list[tuple[str, ...]] = []
        self.downloads: list[tuple[str, int]] = []
        directory = TESTDATA / str(case.get("patch", "workflow-tag-patch"))
        self.patch = (directory / "diff.patch").read_bytes()
        self.metadata = load(directory / "metadata.json")
        self.blobs: dict[str, bytes] = {}
        self.raw: bytes = b""
        texts = cast("dict[str, dict[str, str]]", self.metadata["texts"])
        for index, (path, text) in enumerate(texts.items()):
            old, new = f"{2 * index + 1:040x}", f"{2 * index + 2:040x}"
            self.blobs[old], self.blobs[new] = (
                text["base"].encode(),
                text["head"].encode(),
            )
            if case.get("git") == "rename":
                raw_path = f"previous.yml\0{path}"
                status = "R100"
            else:
                raw_path = path
                status = "M"
            old_mode = "000000" if case.get("git") == "new_file" else "100644"
            self.raw += (
                f":{old_mode} 100644 {old} {new} {status}\0{raw_path}\0".encode()
            )

    def response(self, request: urllib.request.Request) -> Reply:
        parsed = urlsplit(request.full_url)
        assert request.full_url.startswith(f"{API}/")
        path = parsed.path
        if parsed.query:
            path += f"?{parsed.query}"
        method = request.get_method()
        if method != "GET":
            path = f"{method} {path}"
        if method == "POST":
            assert isinstance(request.data, bytes)
            self.posted.append(json.loads(request.data))
        anonymous = "/actions/" in path or not path.removeprefix(
            f"{method} "
        ).startswith(f"/repos/{REPOSITORY}/")
        if anonymous:
            assert not request.has_header("Authorization")
        else:
            assert request.get_header("Authorization") == "Bearer fixture-token"
        count = self.calls[path]
        self.calls[path] += 1
        if path not in self.routes:
            self.unexpected.append(path)
            raise AssertionError(path)
        responses = self.routes[path]
        reply = responses[min(count, len(responses) - 1)]
        if reply.get("timeout"):
            raise TimeoutError
        if reply.get("bad_json"):
            msg = "not JSON"
            raise ValueError(msg)
        headers = cast("dict[str, str]", reply.get("headers", {}))
        if "error" in reply:
            message = Message()
            for key, value in headers.items():
                message[key] = value
            raise urllib.error.HTTPError(
                request.full_url,
                cast("int", reply["error"]),
                "fixture",
                message,
                io.BytesIO(),
            )
        return Reply(reply["body"], headers)

    def git(  # noqa: PLR0911, PLR0912 - dispatches simulated Git commands
        self, cwd: Path, args: tuple[str, ...], env: Mapping[str, str], limit: int
    ) -> bytes:
        assert cwd.is_dir()
        assert env["GIT_TERMINAL_PROMPT"] == "0"
        self.git_calls.append(args)
        variant = self.case.get("git")
        if variant == "unexpected":
            msg = "internal fixture exception"
            raise RuntimeError(msg)
        match args:
            case ("fetch", *_):
                assert args[-2:] == (BASE, HEAD)
                if variant == "fetch_error":
                    msg = "diff_unavailable"
                    raise RefusalError(msg)
            case ("diff", *_, "--raw", "-z", "--no-abbrev", _, _):
                if variant == "raw_error":
                    return b"malformed\0"
                if variant == "raw_encoding":
                    return self.raw[:-1] + b"\xff\0"
                return self.raw
            case ("diff", *_, "--unified=0", _, _):
                return b"x" * (limit + 1) if variant == "patch_limit" else self.patch
            case ("cat-file", "-s", oid):
                if variant == "blob_limit":
                    return str(GIT_TEXT_LIMIT + 1).encode()
                return str(len(self.blobs[oid])).encode()
            case ("cat-file", "blob", oid):
                return b"" if variant == "blob_error" else self.blobs[oid]
            case ("ls-tree", *_):
                return b"lock" if self.metadata["has_mise_lock"] else b""
            case ("init", *_) | ("remote", *_):
                pass
            case _:
                self.unexpected.append(repr(args))
                raise AssertionError(args)
        return b""

    def download(self, url: str, limit: int) -> str | None:
        self.downloads.append((url, limit))
        return cast("str | None", self.case.get("download"))

    def run(self) -> FixtureResult:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            event = load(BASELINE / "event.json")
            if "event" in self.case:
                cast("dict[str, object]", event["workflow_run"])["event"] = self.case[
                    "event"
                ]
            event_path = work / "event.json"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            summary = work / "summary"
            summary.write_text("existing summary\n", encoding="utf-8")
            outputs = work / "outputs"
            outputs.write_text("existing=true\n", encoding="utf-8")
            env = {
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_OUTPUT": str(outputs),
                "GITHUB_STEP_SUMMARY": str(summary),
                "RA_OUTPUT_DIR": str(work),
                "RA_MODE": str(self.case.get("mode", "evaluate")),
                "RA_CHECK_WORKFLOWS": "conclusion: 93",
                "RA_FIRST_PARTY_OWNERS": "example-org",
                "RA_FIRST_PARTY_MODULES": "fixture_rules*",
                **cast("dict[str, str]", self.case.get("env", {})),
            }
            assert (
                main(
                    env,
                    GitHub("fixture-token", self.response, self.waits.append),
                    self.git,
                    self.download,
                )
                == 0
            )
            return FixtureResult(
                load(work / "decision.json"),
                summary.read_text(encoding="utf-8"),
                outputs.read_text(encoding="utf-8"),
            )

    def verify(self) -> FixtureResult:
        result = self.run()
        assert not self.unexpected
        assert result.report["reason"] == self.case["reason"], (result, self.calls)
        assert len(cast("list[str]", result.report["read_times"])) == self.case["reads"]
        assert self.waits == self.case.get("waits", [])
        assert len(self.posted) == self.case.get("posts", 0)
        assert self.calls[
            f"PUT /repos/{REPOSITORY}/pulls/42/reviews/100/dismissals"
        ] == self.case.get("dismissals", 0)
        if "git_calls" in self.case:
            assert len(self.git_calls) == self.case["git_calls"]
        return result


class TestGather(unittest.TestCase):
    def test_recorded_cases(self) -> None:
        for name, case in cases("gather").items():
            with self.subTest(case=name):
                Replay(case).verify()


class _Stream(io.BytesIO):
    headers: ClassVar[dict[str, str]] = {"Content-Type": "application/json"}


class TestTransport(unittest.TestCase):
    def test_http_json_size_limit(self) -> None:
        request = urllib.request.Request(API)  # noqa: S310 - fixed HTTPS fixture
        for body in (b'{"ok": true}', b" " * (API_LIMIT + 1)):
            with self.subTest(size=len(body)):
                opener = Mock()
                opener.open.return_value = _Stream(body)
                with patch("urllib.request.build_opener", return_value=opener):
                    if len(body) > API_LIMIT:
                        with self.assertRaises(ValueError):  # noqa: PT027 - Bazel unittest runner
                            http_json(request)
                    else:
                        assert http_json(request) == Reply(
                            {"ok": True}, _Stream.headers
                        )

    def test_git_runner(self) -> None:
        def git_write(
            *_args: object, stdout: io.BufferedIOBase, **_kwargs: object
        ) -> None:
            stdout.write(b"diff output")

        with patch("subprocess.run", side_effect=git_write) as git:
            assert run_git(Path(), ("diff",), {}, 3) == b"diff"
            assert git.call_args.args[0] == ("git", "diff")
        with (
            patch(
                "subprocess.run", side_effect=subprocess.CalledProcessError(1, "git")
            ),
            self.assertRaisesRegex(RefusalError, "diff_unavailable"),  # noqa: PT027
        ):
            run_git(Path(), ("diff",), {}, 3)

    def test_download_limit_and_transport_failures(self) -> None:
        url = "https://example.org/artifact"
        contents = b"abc"
        entries = (
            (3, _Stream(contents), None, hashlib.sha256(contents).hexdigest()),
            (2, _Stream(contents), None, None),
            (3, _Stream(), OSError("fixture no route"), None),
        )
        for limit, response, failure, expected in entries:
            with self.subTest(limit=limit, failure=failure):
                opener = Mock()
                opener.open.return_value = response
                opener.open.side_effect = failure
                with patch("urllib.request.build_opener", return_value=opener):
                    assert download_digest(url, limit) == expected
        assert download_digest("http://localhost", 1024) is None

    def test_redirects_validate_each_destination(self) -> None:
        request = urllib.request.Request(API)  # noqa: S310 - fixed HTTPS fixture
        headers = http.client.HTTPMessage()
        body = io.BytesIO()
        assert (
            _Redirect().redirect_request(request, body, 302, "", headers, API) is None
        )

        def validate(url: str) -> None:
            assert url.startswith("https://")

        public = _Redirect(validate)
        assert public.redirect_request(request, body, 302, "", headers, API)
        with self.assertRaisesRegex(RefusalError, "digest_unverifiable"):  # noqa: PT027
            _PublicHTTPS().https_open(urllib.request.Request("https://example.org:80"))
        with patch.object(_PublicHTTPS, "do_open", return_value=Mock()) as do_open:
            _PublicHTTPS().https_open(request)
            assert do_open.call_args.args == (_PublicConnection, request)
        connection = _PublicConnection("example.org")
        assert connection.host == "example.org"

    def test_resolve_then_connect(self) -> None:
        public = (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 443))
        fallback = (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("::ffff:1.1.1.1", 443))
        first, second = Mock(), Mock()
        first.connect.side_effect = OSError("fixture refused")
        with (
            patch("socket.getaddrinfo", return_value=[public, fallback]),
            patch("socket.socket", side_effect=[first, second]),
        ):
            assert _connect_public(("example.org", 443), 1.0) is second
            first.close.assert_called_once()
            second.connect.assert_called_once_with(fallback[4])
        with (
            patch("socket.getaddrinfo", return_value=[public]),
            patch("socket.socket", return_value=first),
            self.assertRaisesRegex(OSError, "unreachable"),  # noqa: PT027
        ):
            _connect_public(("example.org", 443), 1.0)
        for address in ("127.0.0.1", "224.0.0.1", "240.0.0.1", "::ffff:127.0.0.1"):
            with (
                self.subTest(address=address),
                patch(
                    "socket.getaddrinfo", return_value=[(*public[:4], (address, 443))]
                ),
                patch("socket.socket") as connect,
                self.assertRaisesRegex(RefusalError, "digest_unverifiable"),  # noqa: PT027
            ):
                _connect_public(("example.org", 443), 1.0)
                connect.assert_not_called()


class TestFacts(unittest.TestCase):
    def test_tag_indirection_is_bounded(self) -> None:
        url = "/repos/actions/checkout/git/ref/tags/v7.0.2"
        sha = "a" * 40
        reply = {"body": {"object": {"type": "tag", "sha": sha}}}
        replay = Replay(
            {
                "extra": {
                    url: [reply],
                    f"/repos/actions/checkout/git/tags/{sha}": [reply],
                }
            }
        )
        api = GitHub("fixture-token", replay.response)
        assert (
            Facts(api, replay.download, BYTES_PER_MEGABYTE).tag(
                "actions/checkout", "v7.0.2"
            )
            == {}
        )
        assert sum(replay.calls.values()) == 2

    def test_public_git_has_no_authentication_header(self) -> None:
        replay = Replay({})
        trigger = Trigger(REPOSITORY, 17, HEAD, 17, 21, 2, 93)
        session = Session(GitHub(""), trigger, {}, {}, BYTES_PER_MEGABYTE)
        files = cast("list[str]", replay.metadata["files"])
        assert git_diff(session, HEAD, BASE, files, replay.git).patch == replay.patch

    def test_digest_download_is_cached(self) -> None:
        replay = Replay({"download": "2" * 64})
        facts = Facts(
            GitHub("fixture-token", replay.response),
            replay.download,
            BYTES_PER_MEGABYTE,
        )
        url = "https://example.org/download"
        assert (
            facts.artifact(url)
            == facts.artifact(url)
            == {"url": url, "sha256": "2" * 64}
        )
        assert replay.downloads == [(url, BYTES_PER_MEGABYTE)]

    def test_starlark_rejects_unusable_evidence(self) -> None:
        replay = Replay(
            {"patch": "archive-commit", "overrides": {"source_ref": [{"error": 404}]}}
        )
        facts = Facts(
            GitHub("fixture-token", replay.response),
            replay.download,
            BYTES_PER_MEGABYTE,
        )
        needed = {"MODULE.bazel": {3}}
        assert pin_facts(replay.patch.decode(), replay.metadata, needed, facts) == {
            "MODULE.bazel": {}
        }
        metadata = {**replay.metadata, "texts": dict[str, object]()}
        assert pin_facts(replay.patch.decode(), metadata, needed, facts) == {}


if __name__ == "__main__":
    unittest.main()
