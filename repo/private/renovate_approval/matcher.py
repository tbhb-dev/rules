# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Match Git patches, pin grammars, and the evidence bound to each pin.

facts[path][str(head_line)] is an object with optional evidence records:

* tag: {repo, name, commit}, with repo in owner/repository form.
* ancestry: {repo, old, new, old_is_ancestor, merged_at_source}. The two
  booleans describe old -> new and new -> source default branch head.
  A tag pin only needs merged_at_source.
* download: {url, sha256}, with sha256 null for a failed or oversized
  download. Otherwise use lowercase hex without a prefix.
* asset: {url_api, browser_download_url} for the exact release asset endpoint.

Place archive ancestry and download evidence on the URL line. For mise.lock
use the head URL line for both download and asset evidence. Facts describe
what gather observed, including a wrong tag target or asset URL.
"""

import base64
import codecs
import io
import json
import re
import tokenize
import tomllib
from collections import Counter
from collections.abc import Iterator  # noqa: TC003 - Python 3.11 evaluates annotations
from dataclasses import dataclass
from fnmatch import fnmatchcase
from typing import NamedTuple, TypeVar, cast
from urllib.parse import urlsplit

from .versions import COMMIT, bump, permit

SELF_PIN = ".github/workflows/renovate-auto-approval.yml"
PIN_FILES = {
    "workflow": (
        ".github/workflows/*.yml",
        ".github/workflows/*.yaml",
        ".github/actions/*/action.yml",
        ".github/actions/*/action.yaml",
    ),
    "starlark": ("MODULE.bazel", "pins/*.bzl"),
    "mise": ("mise.toml",),
    "mise_lock": ("mise.lock",),
    "bazel_lock": ("MODULE.bazel.lock",),
}
_LOCKS = frozenset({"mise_lock", "bazel_lock"})
_HEX_DIGEST = re.compile(r"[0-9a-fA-F]{64}")
_REPO = r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+"
_HUNK = re.compile(
    r"@@ -([0-9]{1,9})(?:,([0-9]{1,9}))? \+([0-9]{1,9})(?:,([0-9]{1,9}))? @@(?: .*)?"
)
_INDEX = re.compile(
    r"index (?:[0-9a-f]{40}|[0-9a-f]{64})\.\."
    r"(?:[0-9a-f]{40}|[0-9a-f]{64})(?: ([0-7]{6}))?"
)
_MODE = re.compile(r"[0-7]{6}")
_PAIR_LENGTH = 2
_ASSIGNMENT_LENGTH = 3
_SHA256_LENGTH = 32
_T = TypeVar("_T")


class Finding(NamedTuple):
    code: str
    path: str
    line: int
    detail: str


class RefusalError(ValueError):
    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(code, detail)
        self.code = code
        self.detail = detail


def _require(condition: object, code: str = "parse_doubt", detail: str = "") -> None:
    if not condition:
        raise RefusalError(code, detail)


def _present(value: _T | None, code: str = "parse_doubt") -> _T:  # noqa: UP047 - also runs on Python 3.11
    if value is None:
        raise RefusalError(code)
    return value


def _object(value: object, code: str = "parse_doubt") -> dict[str, object]:
    if not isinstance(value, dict):
        raise RefusalError(code, "expected an object")
    return cast("dict[str, object]", value)


def objects(value: object, code: str = "parse_doubt") -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise RefusalError(code, "expected an object list")
    return [_object(item, code) for item in cast("list[object]", value)]


def positive_id(value: object) -> bool:
    return type(value) is int and value > 0


def _string(value: object, code: str = "parse_doubt") -> str:
    if not isinstance(value, str):
        raise RefusalError(code, "expected text")
    return value


def _strings(value: object, code: str = "parse_doubt") -> list[str]:
    if not isinstance(value, (list, tuple)):
        raise RefusalError(code, "expected a list of strings")
    return [
        _string(item, code) for item in cast("list[object] | tuple[object, ...]", value)
    ]


@dataclass(frozen=True)
class Config:
    allowed: frozenset[str]
    owners: frozenset[str]
    modules: str
    registry: str
    pin_files: dict[str, tuple[str, ...]]
    max_files: int
    max_commits: int
    opt_out_label: str


def _limit(options: dict[str, object], key: str, default: int) -> int:
    value = options.get(key, default)
    if type(value) is not int or value < 1:
        msg = "parse_doubt"
        raise RefusalError(msg, key)
    return value


def config_from(metadata: dict[str, object]) -> Config:
    options = _object(metadata.get("config", {}))
    allowed = frozenset(
        _strings(options.get("allowed_bumps", ("patch", "minor", "digest")))
    )
    _require(allowed <= {"major", "minor", "patch", "digest"})
    globs = _object(options.get("pin_files", {}))
    _require(globs.keys() <= PIN_FILES.keys())
    registry = _string(options.get("registry", "https://bcr.bazel.build/"))
    _require(registry.startswith(("https://", "http://")))
    return Config(
        allowed,
        frozenset(
            owner.lower()
            for owner in _strings(options.get("first_party_owners", ("tbhb-dev",)))
        ),
        _string(options.get("first_party_modules", "tbhb_rules*")),
        registry.rstrip("/") + "/",
        {kind: tuple(_strings(value)) for kind, value in globs.items()},
        _limit(options, "max_files", 50),
        _limit(options, "max_commits", 5),
        _string(options.get("opt_out_label", "no-auto-approval")),
    )


def _glob(path: str, pattern: str) -> bool:
    return all(
        fnmatchcase(part, glob)
        for part, glob in zip(
            path.split("/"),
            pattern.split("/"),
            strict=False,
        )
    ) and path.count("/") == pattern.count("/")


def _kind(path: str, config: Config) -> str:
    _require(path != SELF_PIN, "self_pin")
    for kind, defaults in PIN_FILES.items():
        if any(_glob(path, glob) for glob in defaults) and any(
            _glob(path, glob) for glob in config.pin_files.get(kind, defaults)
        ):
            return kind
    msg = "not_a_pin_file"
    raise RefusalError(msg)


@dataclass(frozen=True)
class Hunk:
    old: int
    new: int
    removed: tuple[str, ...]
    added: tuple[str, ...]

    def pairs(self) -> Iterator[tuple[int, int]]:
        return zip(
            range(self.old, self.old + len(self.removed)),
            range(self.new, self.new + len(self.added)),
            strict=True,
        )


@dataclass(frozen=True)
class FilePatch:
    path: str
    kind: str
    base: str
    head: str
    hunks: list[Hunk]


def _patch_sections(patch: str) -> list[list[str]]:
    if not patch:
        return []
    _require(patch.endswith("\n"))
    sections: list[list[str]] = []
    for line in patch[:-1].split("\n"):
        if line.startswith("diff --git "):
            sections.append([])
        _require(sections)
        sections[-1].append(line)
    return sections


# cspell:ignore abfnrtv
_QUOTED_PATH = r'"(?:[^"\\]|\\(?:[abfnrtv\\"]|[0-3][0-7]{2}))*"'
_QUOTED_DIFF = re.compile(rf"({_QUOTED_PATH}) ({_QUOTED_PATH})")


def _git_path(path: str) -> str:
    if not path.startswith('"'):
        return path
    _require(re.fullmatch(_QUOTED_PATH, path))
    try:
        return codecs.escape_decode(path[1:-1].encode())[0].decode()
    except UnicodeError as error:
        msg = "encoding"
        raise RefusalError(msg) from error


def _destination(section: list[str]) -> str:
    names = [
        line.removeprefix(prefix)
        for line in section[1:]
        for prefix in ("rename to ", "copy to ")
        if line.startswith(prefix)
    ]
    if names:
        _require(len(names) == 1)
        path = _git_path(names[0])
    else:
        header = section[0].removeprefix("diff --git ")
        if header.startswith('"'):
            match = _present(_QUOTED_DIFF.fullmatch(header))
            left, right = _git_path(match[1]), _git_path(match[2])
        else:
            middle = len(header) // 2
            left, right = header[:middle], header[middle + 1 :]
            _require(header[middle : middle + 1] == " ")
        _require(
            left.startswith("a/") and right.startswith("b/") and left[2:] == right[2:]
        )
        path = right[2:]
    _require(not any(char in path for char in "\x00\n\r"))
    _require(all(part not in {"", ".", ".."} for part in path.split("/")))
    return path


_HEADER_CODES = (
    (("copy from ", "copy to "), "copy"),
    (
        ("rename from ", "rename to ", "similarity index ", "dissimilarity index "),
        "rename",
    ),
    (("new file mode ",), "new_file"),
    (("deleted file mode ",), "deleted_file"),
    (("old mode ", "new mode "), "mode_change"),
    (("Binary files ", "GIT binary patch"), "binary"),
)


def _file_headers(path: str, lines: list[str], modes: dict[str, object]) -> list[str]:
    end = next((i for i, line in enumerate(lines) if line.startswith("@@")), len(lines))
    headers = lines[:end]
    for prefixes, code in _HEADER_CODES:
        _require(not any(line.startswith(prefixes) for line in headers), code)
    raw = _strings(modes.get(path))
    _require(len(raw) == _PAIR_LENGTH and all(_MODE.fullmatch(mode) for mode in raw))
    _require(not {"120000", "160000"}.intersection(raw), "submodule_or_symlink")
    _require(raw[0] == raw[1], "mode_change")
    _require(raw[0] in {"100644", "100755"})
    if not lines:
        return []
    index = _INDEX.fullmatch(headers[0]) if headers else None
    _require(index is not None and index.group(1) in {None, raw[0]})
    if end < len(lines) or len(headers) != 1:
        _require(len(headers) == _ASSIGNMENT_LENGTH)
        old, new = (header.removesuffix("\t") for header in headers[1:])
        _require(old.startswith("--- ") and new.startswith("+++ "))
        _require(
            _git_path(old[4:]) == f"a/{path}" and _git_path(new[4:]) == f"b/{path}"
        )
    return lines[end:]


def _hunks(lines: list[str]) -> list[Hunk]:
    _require(r"\ No newline at end of file" not in lines, "eol_change")
    hunks = []
    cursor = 0
    while cursor < len(lines):
        hunk, cursor = _read_hunk(lines, cursor)
        hunks.append(hunk)
    return hunks


def _read_hunk(lines: list[str], cursor: int) -> tuple[Hunk, int]:
    match = _HUNK.fullmatch(lines[cursor])
    if match is None:
        msg = "parse_doubt"
        raise RefusalError(msg, "invalid hunk header")
    old, old_count, new, new_count = (int(part or "1") for part in match.groups())
    count = old_count + new_count
    end = cursor + 1 + count
    body = lines[cursor + 1 : end]
    _require(count and len(body) == count)
    removed, added = body[:old_count], body[old_count:]
    _require(all(line.startswith("-") for line in removed))
    _require(all(line.startswith("+") for line in added))
    _require((old > 0 or not old_count) and (new > 0 or not new_count))
    return Hunk(
        old,
        new,
        tuple(line[1:] for line in removed),
        tuple(line[1:] for line in added),
    ), end


def _content_lines(text: str) -> list[str]:
    try:
        text.encode()
    except UnicodeError as error:
        msg = "encoding"
        raise RefusalError(msg) from error
    _require("\r" not in text and "\x00" not in text, "encoding")
    _require(not text or text.endswith("\n"), "eol_change")
    return text[:-1].split("\n") if text else []


def _verify_hunks(base: str, head: str, hunks: list[Hunk]) -> None:
    old_lines, new_lines = _content_lines(base), _content_lines(head)
    old_end = new_end = 0
    for hunk in hunks:
        old_start = hunk.old - bool(hunk.removed)
        new_start = hunk.new - bool(hunk.added)
        _require(old_end <= old_start <= len(old_lines))
        _require(new_end <= new_start <= len(new_lines))
        _require(old_lines[old_end:old_start] == new_lines[new_end:new_start])
        old_end, new_end = old_start + len(hunk.removed), new_start + len(hunk.added)
        _require(tuple(old_lines[old_start:old_end]) == hunk.removed)
        _require(tuple(new_lines[new_start:new_end]) == hunk.added)
    _require(old_lines[old_end:] == new_lines[new_end:])


def _counts(hunk: Hunk) -> None:
    _require(hunk.removed, "line_added")
    _require(hunk.added, "line_removed")
    _require(len(hunk.removed) == len(hunk.added), "line_count_changed")


def _read_file(
    path: str, lines: list[str], metadata: dict[str, object], config: Config
) -> FilePatch:
    kind = _kind(path, config)
    hunks = _hunks(_file_headers(path, lines, _object(metadata.get("modes"))))
    _require(hunks, "empty_diff")
    texts = _object(_object(metadata.get("texts")).get(path))
    base, head = _string(texts.get("base")), _string(texts.get("head"))
    _verify_hunks(base, head, hunks)
    return FilePatch(path, kind, base, head, hunks)


@dataclass(frozen=True)
class Change:
    old: str
    new: str


class Evidence:
    def __init__(self, facts: object, path: str, line: int) -> None:
        self.facts = facts
        self.path = path
        self.line = line

    def record(self, key: str, **binding: str) -> dict[str, object]:
        paths = _object(self.facts, "fact_missing")
        lines = _object(paths.get(self.path), "fact_missing")
        facts = _object(lines.get(str(self.line)), "fact_missing")
        record = _object(facts.get(key), "fact_missing")
        _require(
            all(record.get(k) == value for k, value in binding.items()),
            "fact_missing",
            key,
        )
        return record

    def ancestry(self, repo: str, change: Change, *, branch: bool) -> None:
        ancestry = self.record("ancestry", repo=repo, old=change.old, new=change.new)
        if branch:
            _require_fact_bool(ancestry, "old_is_ancestor", "downgrade")
        _require_fact_bool(ancestry, "merged_at_source", "not_merged_at_source")

    def digest(self, url: str, expected: str) -> None:
        download = self.record("download", url=url)
        digest = download.get("sha256", "")
        _require(digest is not None, "digest_unverifiable")
        _require(
            isinstance(digest, str) and _HEX_DIGEST.fullmatch(digest), "fact_missing"
        )
        _require(digest == expected.lower(), "digest_mismatch")


def _require_fact_bool(record: dict[str, object], key: str, code: str) -> None:
    value = record.get(key)
    _require(type(value) is bool, "fact_missing", key)
    _require(value, code, key)


def _passed(code: str | None) -> None:
    if code is not None:
        raise RefusalError(code)


_USES = re.compile(
    rf" *(?:- )?uses: (?P<repo>{_REPO})(?:/[A-Za-z0-9_.-]+)*"
    r"@(?P<commit>[a-f0-9]{40})(?:  # (?P<version>[^ #\t]+))?"
)
_YAML_KEY = re.compile(
    r"""(?:([A-Za-z0-9_.-]+)|"([A-Za-z0-9_.-]+)"|'([A-Za-z0-9_.-]+)'):(?: |$)(.*)"""
)
_YAML_FLOW_CLOSING = {"]": "[", "}": "{"}


@dataclass
class _YamlBlock:
    indent: int
    edge: str
    leaf: bool
    seen: set[str]
    children: tuple[int, bool] | None = None


def _yaml_parent(stack: list[_YamlBlock], indent: int, *, sequence: bool) -> _YamlBlock:
    while len(stack) > 1 and indent <= stack[-1].indent:
        if (
            sequence
            and not stack[-1].leaf
            and stack[-1].edge != "[]"
            and indent == stack[-1].indent
        ):
            break
        stack.pop()
    return stack[-1]


def _yaml_flow_end(value: str, stack: list[str]) -> None:
    escaped = False
    for i, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        top = stack[-1] if stack else ""
        if top in {'"', "'"}:
            escaped = char == "\\" and top == '"'
            if char == top:
                stack.pop()
            continue
        if char == "#" and (not i or value[i - 1].isspace()):
            break
        _yaml_flow_delimiter(char, top, stack)


def _yaml_flow_delimiter(char: str, top: str, stack: list[str]) -> None:
    if char in "{[\"'":
        stack.append(char)
    if char in _YAML_FLOW_CLOSING:
        _require(_YAML_FLOW_CLOSING[char] == top)
        stack.pop()


class _WorkflowYaml:
    def __init__(self, path: str) -> None:
        self.path = path
        self.stack = [_YamlBlock(-1, "", leaf=False, seen=set())]
        self.flow: list[str] = []
        self.uses: set[int] = set()

    def scan(self, text: str) -> set[int]:
        started = False
        for number, original in enumerate(_content_lines(text), 1):
            if self.flow:
                _yaml_flow_end(original, self.flow)
                continue
            content = original.lstrip(" ")
            if not content or content.startswith("#"):
                continue
            if not started and original == "---":
                started = True
                continue
            started = True
            self.line(content, len(original) - len(content), number)
        _require(not self.flow)
        return self.uses

    def line(self, content: str, indent: int, number: int) -> None:
        _require(not content.startswith("\t"))
        sequence = content == "-" or content.startswith("- ")
        parent = _yaml_parent(self.stack, indent, sequence=sequence)
        if parent.leaf:
            _require(parent.edge != "uses")
            return
        _require(parent.children in {None, (indent, sequence)})
        parent.children = indent, sequence
        if sequence:
            parent = _YamlBlock(indent, "[]", leaf=False, seen=set())
            self.stack.append(parent)
            item = content[1:].lstrip(" ")
            indent += len(content) - len(item)
            content = item
        if not content or content.startswith("#"):
            return
        match = _YAML_KEY.fullmatch(content)
        if sequence and match is None:
            self.value(content)
            parent.leaf = True
            return
        self.entry(parent, _present(match), indent, number)

    def entry(
        self,
        parent: _YamlBlock,
        match: re.Match[str],
        indent: int,
        number: int,
    ) -> None:
        key = next(part for part in match.groups()[:3] if part is not None)
        value = match[4].lstrip(" ")
        _require(key not in parent.seen)
        parent.seen.add(key)
        edges = [block.edge for block in self.stack[1:]]
        if key == "uses" and _uses_scope(self.path, edges):
            self.uses.add(number)
        if parent.edge == "[]":
            _require(parent.children in {None, (indent, False)})
            parent.children = indent, False
        self.value(value)
        leaf = bool(value and not value.startswith("#"))
        self.stack.append(_YamlBlock(indent, key, leaf, set()))

    def value(self, value: str) -> None:
        _require(not value.startswith(("!", "&")))
        if value.startswith(("[", "{", '"', "'")):
            _yaml_flow_end(value, self.flow)


def _uses_scope(path: str, edges: list[str]) -> bool:
    if path.startswith(".github/actions/"):
        return edges == ["runs", "steps", "[]"]
    return (
        len(edges) >= _PAIR_LENGTH
        and edges[0] == "jobs"
        and edges[2:] in ([], ["steps", "[]"])
    )


def _workflow_pair(
    old_line: str,
    new_line: str,
    *,
    scope: bool,
    evidence: Evidence,
    config: Config,
) -> None:
    _require(scope, "not_a_pin_line")
    old = _present(_USES.fullmatch(old_line), "not_a_pin_line")
    new = _present(_USES.fullmatch(new_line), "not_a_pin_line")
    _require(old["version"] and new["version"], "unversioned_pin")
    _require(
        _blank(old_line, (old.span("commit"), old.span("version")))
        == _blank(new_line, (new.span("commit"), new.span("version"))),
        "key_changed",
    )
    commits = Change(old["commit"], new["commit"])
    _require(
        commits.old != commits.new or old["version"] != new["version"],
        "no_value_change",
    )
    _require(commits.old != commits.new, "comment_only_change")
    repo = new["repo"]
    owner = repo.split("/")[0].lower()
    if new["version"] == old["version"] == "main":
        _require(owner in config.owners, "not_first_party")
        _passed(permit("digest", config.allowed))
        evidence.ancestry(repo, commits, branch=True)
        return
    _passed(bump(old["version"], new["version"], config.allowed))
    tag = evidence.record("tag", repo=repo, name=new["version"])
    _require("commit" in tag, "fact_missing")
    _require(tag["commit"] == commits.new, "tag_mismatch")
    if owner in config.owners:
        evidence.ancestry(repo, commits, branch=False)


def _blank(line: str, spans: tuple[tuple[int, int], ...]) -> str:
    for start, end in sorted(spans, reverse=True):
        line = line[:start] + "\x00" + line[end:]
    return line


_STAR_SLOTS = {
    "bazel_dep": {"version"},
    "git_override": {"commit"},
    "single_version_override": set(),
    "http_archive": {"url", "urls", "strip_prefix", "sha256", "integrity"},
    "http_file": {"url", "urls", "strip_prefix", "sha256", "integrity"},
    "archive_override": {"url", "urls", "strip_prefix", "sha256", "integrity"},
}
_STAR_IGNORE = {
    tokenize.INDENT,
    tokenize.DEDENT,
    tokenize.COMMENT,
    tokenize.NL,
    tokenize.NEWLINE,
    tokenize.ENDMARKER,
}
_OPEN = {"(": ")", "[": "]", "{": "}"}
_LITERAL = re.compile(r"""(?:"([^"\\]*)"|'([^'\\]*)')""")


@dataclass(frozen=True)
class Slot:
    value: str
    line: int
    span: tuple[int, int]


@dataclass(frozen=True)
class Call:
    order: int
    name: str
    start: int
    end: int
    shape: tuple[str, str]
    body: list[tokenize.TokenInfo]
    continued: bool


def _star_tokens(text: str) -> list[tokenize.TokenInfo]:
    try:
        return [
            token
            for token in tokenize.generate_tokens(io.StringIO(text).readline)
            if token.type not in _STAR_IGNORE
        ]
    except (SyntaxError, tokenize.TokenError) as error:
        msg = "parse_doubt"
        raise RefusalError(msg, "invalid Starlark tokens") from error


def _star_calls(text: str) -> dict[int, Call]:
    tokens = _star_tokens(text)
    stack: list[int] = []
    lines = _content_lines(text)
    calls: dict[int, Call] = {}
    order = 0
    for index, token in enumerate(tokens):
        if token.string in _OPEN:
            stack.append(index)
        elif token.string in _OPEN.values():
            _require(stack and _OPEN[tokens[stack[-1]].string] == token.string)
            opening = stack.pop()
            if not stack and opening:
                call = _star_call(tokens, opening, index, order, lines)
                if call is not None:
                    calls.update(dict.fromkeys(range(call.start, call.end + 1), call))
                    order += 1
    _require(not stack)
    return calls


def _star_call(
    tokens: list[tokenize.TokenInfo],
    opening: int,
    closing: int,
    order: int,
    lines: list[str],
) -> Call | None:
    name, left, right = tokens[opening - 1], tokens[opening], tokens[closing]
    prefix = name.line[: name.start[1]]
    if (
        name.string not in _STAR_SLOTS
        or prefix.strip()
        or "\t" in prefix
        or left.string != "("
    ):
        return None
    _require(name.start[0] == left.start[0])
    _require(
        not right.line[right.end[1] :].strip()
        or right.line[right.end[1] :].lstrip().startswith("#")
    )
    return Call(
        order,
        name.string,
        name.start[0],
        right.end[0],
        (left.line[: left.end[1]], right.line[right.end[1] :]),
        tokens[opening + 1 : closing],
        any(
            line.endswith("\\")
            for line in lines[max(0, name.start[0] - 2) : right.end[0]]
        ),
    )


def _arguments(call: Call) -> dict[str, list[tokenize.TokenInfo]]:
    arguments = {}
    part: list[tokenize.TokenInfo] = []
    depth = 0
    for token in call.body:
        if token.string == "," and not depth:
            _add_argument(arguments, part)
            part = []
            continue
        depth += (token.string in _OPEN) - (token.string in _OPEN.values())
        part.append(token)
    if part:
        _add_argument(arguments, part)
    return arguments


def _add_argument(
    arguments: dict[str, list[tokenize.TokenInfo]],
    part: list[tokenize.TokenInfo],
) -> None:
    _require(
        len(part) >= _ASSIGNMENT_LENGTH
        and part[0].type == tokenize.NAME
        and part[1].string == "="
    )
    key = part[0].string
    _require(key not in arguments)
    arguments[key] = part


def _literal_slot(assignment: list[tokenize.TokenInfo], key: str) -> Slot:
    tokens = assignment[2:]
    if key == "urls":
        _require(
            len(tokens) == _ASSIGNMENT_LENGTH
            and tokens[0].string == "["
            and tokens[-1].string == "]"
            and tokens[0].start[0] == tokens[-1].end[0]
        )
        tokens = tokens[1:2]
    _require(len(tokens) == 1 and tokens[0].type == tokenize.STRING)
    token = tokens[0]
    _require(_LITERAL.fullmatch(token.string))
    _require(token.start[0] == token.end[0] == assignment[0].start[0])
    return Slot(
        token.string[1:-1], token.start[0], (token.start[1] + 1, token.end[1] - 1)
    )


def _star_fields(
    call: Call,
    line: int,
) -> tuple[str, dict[str, Slot]]:
    _require(not call.continued)
    _require(
        not any(
            token.string in _OPEN and _spans_lines(call.body, index)
            for index, token in enumerate(call.body)
        )
    )
    _require(
        not any(token.string == "+" and token.start[0] == line for token in call.body)
    )
    arguments = _arguments(call)
    identity = (
        "name"
        if call.name in {"bazel_dep", "http_archive", "http_file"}
        else "module_name"
    )
    name = _literal_slot(arguments.get(identity, []), identity).value
    slots = {
        key: _literal_slot(tokens, key)
        for key, tokens in arguments.items()
        if key in _STAR_SLOTS[call.name]
    }
    if call.name == "git_override":
        slots["remote"] = _literal_slot(arguments.get("remote", []), "remote")
    return name, slots


def _spans_lines(tokens: list[tokenize.TokenInfo], opening: int) -> bool:
    line = tokens[opening].start[0]
    depth = 0
    remaining = iter(tokens[opening:])
    while True:
        token = next(remaining)
        if token.start[0] != line or token.end[0] != line:
            return True
        depth += (token.string in _OPEN) - (token.string in _OPEN.values())
        if not depth:
            return False


def _star_pair(
    before: Call,
    after: Call,
    old_line: tuple[int, str],
    new_line: tuple[int, str],
) -> tuple[str, dict[str, Slot], dict[str, Slot]]:
    _require(before.name == after.name, "mixed_line_kinds")
    old, old_text = old_line
    new, new_text = new_line
    name, left = _star_fields(before, old)
    other, right = _star_fields(after, new)
    old_keys = {key for key, slot in left.items() if slot.line == old} & _STAR_SLOTS[
        before.name
    ]
    new_keys = {key for key, slot in right.items() if slot.line == new} & _STAR_SLOTS[
        after.name
    ]
    _require(old_keys and new_keys, "not_a_pin_line")
    _require(old_keys == new_keys, "mixed_line_kinds")
    _require(
        before.order == after.order
        and before.shape == after.shape
        and name == other
        and _blank(old_text, tuple(left[key].span for key in old_keys))
        == _blank(new_text, tuple(right[key].span for key in new_keys)),
        "key_changed",
    )
    _require(
        any(left[key].value != right[key].value for key in old_keys), "no_value_change"
    )
    return name, left, right


_REPOSITORY = re.compile(rf"https://github\.com/({_REPO})(?:/.*)?")
_REMOTE = re.compile(
    rf"(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)({_REPO})"
)


def _git_override(
    module: str,
    left: dict[str, Slot],
    right: dict[str, Slot],
    evidence: Evidence,
    config: Config,
) -> None:
    change = Change(left["commit"].value, right["commit"].value)
    _require(COMMIT.fullmatch(change.old) and COMMIT.fullmatch(change.new))
    remote = _REMOTE.fullmatch(right["remote"].value.removesuffix(".git"))
    _require(
        remote
        and remote[1].split("/")[0].lower() in config.owners
        and fnmatchcase(module, config.modules),
        "not_first_party",
    )
    _passed(permit("digest", config.allowed))
    evidence.ancestry(_present(remote, "not_first_party")[1], change, branch=True)


_URL_TOKEN = re.compile(
    r"(?<![A-Za-z0-9.])v?([a-f0-9]{40}|[0-9]+(?:\.[0-9]+)*"
    r"(?:(?:\+|-(?:alpha|beta|rc|pre|dev|snapshot))[A-Za-z0-9.-]*"
    r"|-[A-Za-z0-9][A-Za-z0-9.-]*(?=/))?)"
    r"(?![A-Za-z0-9]|\.[0-9])",
    re.IGNORECASE,
)


def _url_parts(value: str) -> tuple[str, str]:
    try:
        url = urlsplit(value)
    except ValueError as error:
        msg = "url_changed_beyond_version"
        raise RefusalError(msg) from error
    prefix = f"{url.scheme}://{url.netloc}"
    _require(
        url.scheme in {"http", "https"}
        and url.hostname
        and url.username is None
        and value.startswith(prefix)
        and not any(char.isspace() for char in value),
        "url_changed_beyond_version",
    )
    return prefix, value[len(prefix) :]


def _tokens_at(value: str, offset: int) -> set[str]:
    return {
        match[1]
        for match in _URL_TOKEN.finditer(value)
        if match.start() <= offset <= match.end()
    }


def _version_template(value: str, version: str) -> str:
    return _URL_TOKEN.sub(
        lambda match: "\x00" if match[1] == version else match[0], value
    )


def _url_version(old: str, new: str, change: Change | None = None) -> Change:
    old_prefix, old_tail = _url_parts(old)
    new_prefix, new_tail = _url_parts(new)
    _require(old_prefix == new_prefix, "url_changed_beyond_version")
    if old_prefix == "https://github.com":
        _require(
            old_tail.split("/")[:3] == new_tail.split("/")[:3],
            "url_changed_beyond_version",
        )
    offset = next(
        (
            index
            for index, (left, right) in enumerate(zip(old_tail, new_tail, strict=False))
            if left != right
        ),
        min(len(old_tail), len(new_tail)),
    )
    before = {change.old.removeprefix("v")} if change else _tokens_at(old_tail, offset)
    after = {change.new.removeprefix("v")} if change else _tokens_at(new_tail, offset)
    options = [
        Change(left, right)
        for left in sorted(before)
        for right in sorted(after)
        if old_tail != new_tail
        and _version_template(old_tail, left) == _version_template(new_tail, right)
        and _version_template(old_tail, left) != old_tail
    ]
    _require(len(options) == 1, "url_changed_beyond_version")
    return options[0]


def _digest_value(field: str, value: str) -> str:
    if field == "sha256":
        _require(_HEX_DIGEST.fullmatch(value))
        return value.lower()
    _require(value.startswith("sha256-"))
    try:
        decoded = base64.b64decode(value.removeprefix("sha256-"), validate=True)
    except ValueError as error:
        msg = "parse_doubt"
        raise RefusalError(msg, "invalid SHA-256 integrity") from error
    _require(len(decoded) == _SHA256_LENGTH)
    return decoded.hex()


def _one_slot(slots: dict[str, Slot], keys: tuple[str, ...]) -> str:
    present = [key for key in keys if key in slots]
    _require(len(present) == 1)
    return present[0]


def _archive(
    left: dict[str, Slot],
    right: dict[str, Slot],
    config: Config,
    evidence: Evidence,
) -> None:
    url_key = _one_slot(right, ("url", "urls"))
    digest_key = _one_slot(right, ("sha256", "integrity"))
    _require(left.keys() == right.keys(), "mixed_line_kinds")
    url = right[url_key].value
    old_url = left[url_key].value
    old_digest = _digest_value(digest_key, left[digest_key].value)
    digest = _digest_value(digest_key, right[digest_key].value)
    if old_url == url:
        code = (
            "digest_without_version_change"
            if old_digest != digest
            else "url_changed_beyond_version"
        )
        raise RefusalError(code)
    change = _url_version(old_url, url)
    if "strip_prefix" in right:
        before = left["strip_prefix"].value
        after = right["strip_prefix"].value
        _require(
            _version_template(before, change.old)
            == _version_template(after, change.new),
            "url_changed_beyond_version",
        )
    _require(old_digest != digest, "digest_not_updated")
    _archive_bump(change, url, evidence, config)
    evidence.digest(url, digest)


def _archive_bump(change: Change, url: str, evidence: Evidence, config: Config) -> None:
    if COMMIT.fullmatch(change.old) and COMMIT.fullmatch(change.new):
        repo = _REPOSITORY.fullmatch(url)
        _require(
            repo and repo[1].split("/")[0].lower() in config.owners, "not_first_party"
        )
        _passed(permit("digest", config.allowed))
        evidence.ancestry(_present(repo, "not_first_party")[1], change, branch=True)
    else:
        _passed(bump(change.old, change.new, config.allowed))


_TOML_TOKEN = re.compile(
    r""""{3}(?:\\[\s\S]|"(?!"")|[^"\\])*"{3}"{0,2}"""
    r"""|'{3}(?:'(?!'')|[^'])*'{3}'{0,2}"""
    r"""|"(?:\\.|[^"\n\\])*"|'[^'\n]*'|#[^\n]*|[\[\]{}\n]"""
)
_INLINE_TOML_TOKEN = re.compile(
    r""""(?:\\.|[^"\\])*"|'[^']*'|[\[\]{},=]|[A-Za-z0-9_-]+"""
)
_MISE_EXACT = re.compile(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:[+-][^ ]+)?")


@dataclass(frozen=True)
class Statement:
    start: int
    end: int
    text: str


def _toml(text: str) -> dict[str, object]:
    try:
        return tomllib.loads(text)
    except (ValueError, RecursionError) as error:
        msg = "parse_doubt"
        raise RefusalError(msg, "invalid TOML") from error


def _toml_statements(text: str) -> Iterator[Statement]:
    # The full document has already passed tomllib. Track statement ends so
    # quoted multiline data can never be interpreted as a header or field.
    depth, start, number = 0, 0, 1
    first = number
    for match in _TOML_TOKEN.finditer(text):
        fragment = match[0]
        depth += (fragment in {"[", "{"}) - (fragment in {"]", "}"})
        if fragment == "\n" and not depth:
            line = text[start : match.start()].lstrip()
            if line and not line.startswith("#"):
                yield Statement(first, number, line)
            start, first = match.end(), number + 1
        number += fragment.count("\n")


def _table(header: str) -> tuple[str, ...]:
    row: object = _toml(header + "\nrenovate_approval_sentinel = true")
    parts = []
    while isinstance(row, dict) and "renovate_approval_sentinel" not in row:
        _require(len(row) == 1)
        key, row = next(iter(_object(row).items()))
        parts.append(key)
        if isinstance(row, list):
            row = row[0]
    _require(isinstance(row, dict))
    return tuple(parts)


def _tool_slots(text: str) -> dict[int, tuple[str, Slot]]:
    _toml(text)
    lines = _content_lines(text)
    section: tuple[str, ...] = ()
    tools: dict[int, tuple[str, Slot]] = {}
    for statement in _toml_statements(text):
        if statement.text.startswith("["):
            section = _table(statement.text)
        elif section == ("tools",) and statement.start == statement.end:
            key, parsed = next(iter(_toml(statement.text).items()))
            value = parsed.get("version") if isinstance(parsed, dict) else parsed
            if isinstance(value, str):
                line = lines[statement.start - 1]
                slot = _tool_slot(line, statement.start, value)
                tools[statement.start] = key, slot
    return tools


def _tool_slot(line: str, number: int, value: str) -> Slot:
    tokens = list(_INLINE_TOML_TOKEN.finditer(line))
    _require(len(tokens) >= _ASSIGNMENT_LENGTH and tokens[1][0] == "=")
    if tokens[2][0] != "{":
        field = tokens[2]
    else:
        fields = []
        depth = 1
        fields_tokens = enumerate(tokens[3:], 3)
        while depth:
            index, token = next(fields_tokens)
            if (
                depth == 1
                and token[0].strip("'\"") == "version"
                and (tokens[index - 1][0] in {"{", ","} and tokens[index + 1][0] == "=")
            ):
                fields.append(tokens[index + 2])
            depth += (token[0] in {"[", "{"}) - (token[0] in {"]", "}"})
        _require(len(fields) == 1)
        field = fields[0]
    _require(field[0][0] in {'"', "'"} and field[0][1:-1] == value)
    return Slot(value, number, (field.start() + 1, field.end() - 1))


def _mise_pair(
    left: tuple[str, Slot] | None,
    right: tuple[str, Slot] | None,
    old_line: str,
    new_line: str,
    config: Config,
) -> tuple[str, Change]:
    key, old = _present(left, "not_a_pin_line")
    new_key, new = _present(right, "not_a_pin_line")
    _require(
        key == new_key
        and _blank(old_line, (old.span,)) == _blank(new_line, (new.span,)),
        "key_changed",
    )
    _require(old.value != new.value, "no_value_change")
    _require(
        _MISE_EXACT.fullmatch(old.value) and _MISE_EXACT.fullmatch(new.value),
        "unpinned_version",
    )
    _passed(bump(old.value, new.value, config.allowed))
    return key, Change(old.value, new.value)


_RegistryEntry = tuple[int, int, int | None]
_JSON_SPACE = re.compile(r"[ \n\t]*")


def _unique_object(items: list[tuple[str, object]]) -> dict[str, object]:
    result = dict(items)
    _require(len(result) == len(items), "parse_doubt", "duplicate JSON key")
    return result


def _invalid_constant(value: str) -> object:
    msg = "parse_doubt"
    raise RefusalError(msg, value)


_JSON = json.JSONDecoder(
    object_pairs_hook=_unique_object, parse_constant=_invalid_constant
)


def _json_object(text: str) -> dict[str, object]:
    try:
        return _object(_JSON.decode(text))
    except (ValueError, RecursionError) as error:
        msg = "parse_doubt"
        raise RefusalError(msg, "invalid lock JSON") from error


def _skip_space(text: str, start: int) -> int:
    return _present(_JSON_SPACE.match(text, start)).end()


def _json_members(text: str, start: int) -> Iterator[tuple[str, int, _RegistryEntry]]:
    # The entire JSON document has already been validated, including duplicates.
    pos = _skip_space(text, start + 1)
    while text[pos] != "}":
        key, key_end = _JSON.raw_decode(text, pos)
        value_start = _skip_space(text, _skip_space(text, key_end) + 1)
        _, end = _JSON.raw_decode(text, value_start)
        delimiter = _skip_space(text, end)
        comma = delimiter if text[delimiter] == "," else None
        yield key, value_start, (pos, end, comma)
        pos = _skip_space(text, delimiter + 1) if comma is not None else delimiter


def _equal(left: object, right: object) -> bool:
    # Plain dict/list equality treats True as 1 and 1 as 1.0.
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        fields, other = _object(left), _object(right)
        return fields.keys() == other.keys() and all(
            _equal(fields[key], other[key]) for key in fields
        )
    if isinstance(left, list):
        first, second = cast("list[object]", left), cast("list[object]", right)
        return len(first) == len(second) and all(
            _equal(old, new) for old, new in zip(first, second, strict=True)
        )
    return left == right


def _omit(fields: dict[str, object], *keys: str) -> dict[str, object]:
    return {key: value for key, value in fields.items() if key not in keys}


_REGISTRY_MODULE = re.compile(
    r"https?://[^/]+(?:/[^/]+)*/modules/([^/]+)/([^/]+)/[^/]+"
)


def _registry_pin(key: str) -> tuple[str, str]:
    match = _present(_REGISTRY_MODULE.fullmatch(key), "lock_key_changed")
    return match[1], match[2]


def _registry_value(value: object) -> bool:
    return value is None or (
        isinstance(value, str) and bool(_HEX_DIGEST.fullmatch(value))
    )


def _bazel_lock(
    file: FilePatch, pins: dict[str, Change], config: Config, overrides: dict[str, str]
) -> None:
    _require(pins, "lock_changed_without_pin")
    base, head = _json_object(file.base), _json_object(file.head)
    _require(
        _equal(_omit(base, "registryFileHashes"), _omit(head, "registryFileHashes")),
        "lock_key_changed",
    )
    before = _object(base.get("registryFileHashes"), "lock_key_changed")
    after = _object(head.get("registryFileHashes"), "lock_key_changed")
    removed, added = before.keys() - after.keys(), after.keys() - before.keys()
    _require(
        all(_equal(before[key], after[key]) for key in before.keys() & after.keys()),
        "lock_key_changed",
    )
    previous = {(module, change.old) for module, change in pins.items()}
    previous.update(
        (module, overrides[module]) for module in pins.keys() & overrides.keys()
    )
    current = {(module, change.new) for module, change in pins.items()}
    touched = {_permitted_registry_key(key, previous) for key in sorted(removed)} | {
        _permitted_registry_key(key, current, config.registry, after[key])
        for key in sorted(added)
    }
    _require(
        _registry_projection(file.base, removed)
        == _registry_projection(file.head, added),
        "lock_key_changed",
        "change outside registry entries or their delimiters",
    )
    for module, change in sorted(pins.items()):
        prefix = f"{config.registry}modules/{module}/{change.new}/"
        _require(module in touched, "lock_not_updated", module)
        for key in ("MODULE.bazel", "source.json"):
            path = prefix + key
            _require(path in after, "lock_not_updated", path)
            _require(_registry_value(after[path]), "lock_key_changed", path)


def _permitted_registry_key(
    key: str,
    allowed: set[tuple[str, str]],
    registry: str = "",
    value: object = None,
) -> str:
    pin = _registry_pin(key)
    _require(
        pin in allowed and key.startswith(registry) and _registry_value(value),
        "lock_key_changed",
        key,
    )
    return pin[0]


def _registry_projection(text: str, removed: set[str]) -> str:
    start = next(
        value
        for key, value, _ in _json_members(text, _skip_space(text, 0))
        if key == "registryFileHashes"
    )
    members = list(_json_members(text, start))
    retained = [begin for key, _, (begin, _, _) in members if key not in removed]
    if not retained:
        closing = _skip_space(text, members[-1][2][1] if members else start + 1)
        return text[: start + 1] + text[closing:]
    cuts = []
    for key, _, (begin, end, comma) in members:
        if key in removed:
            cuts.append((begin, end if comma is None else comma + 1))
        elif begin == retained[-1] and comma is not None:
            cuts.append((comma, comma + 1))
    return _erase_entries(text, _merge_cuts(text, cuts))


def _merge_cuts(text: str, cuts: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for start, end in cuts:
        begin = start
        if merged and not text[merged[-1][1] : begin].strip(" \t"):
            begin = merged.pop()[0]
        merged.append((begin, end))
    return merged


def _erase_entries(text: str, cuts: list[tuple[int, int]]) -> str:
    for start, stop in reversed(cuts):
        begin, end = start, stop
        left = text.rfind("\n", 0, begin) + 1
        right = text.find("\n", end)
        if not text[left:begin].strip() and not text[end:right].strip():
            begin, end = left, right + 1
        elif text[begin] != ",":
            while end < right and text[end] in " \t":
                end += 1
        text = text[:begin] + text[end:]
    return text


_MISE_ASSET = re.compile(
    rf"https://api\.github\.com/repos/({_REPO})/releases/assets/[0-9]+"
)
_MISE_VERSION_FIELDS = ("version", "specifiers")
_MISE_PLATFORM_FIELDS = ("url", "url_api", "checksum")


def _platforms(entry: dict[str, object]) -> tuple[dict[str, object], dict[str, object]]:
    stable: dict[str, object] = {}
    platforms: dict[str, object] = {}
    for key, value in entry.items():
        if key.startswith("platforms."):
            nested = {key.removeprefix("platforms."): value}
        elif key == "platforms":
            nested = _object(value, "lock_key_changed")
        else:
            stable[key] = value
            continue
        _require(not nested.keys() & platforms.keys(), "lock_key_changed")
        platforms.update(nested)
    return stable, platforms


def _mise_platform(
    before: dict[str, object],
    after: dict[str, object],
    change: Change,
    evidence: Evidence,
) -> None:
    _require(
        _equal(
            _omit(before, *_MISE_PLATFORM_FIELDS), _omit(after, *_MISE_PLATFORM_FIELDS)
        ),
        "lock_key_changed",
    )
    old_url, url = (_string(p.get("url"), "lock_key_changed") for p in (before, after))
    _url_version(old_url, url, change)
    checksum = _string(after.get("checksum"), "digest_mismatch")
    _require(
        checksum.startswith("sha256:") and _HEX_DIGEST.fullmatch(checksum[7:]),
        "digest_mismatch",
    )
    evidence.digest(url, checksum[7:])
    _require(("url_api" in before) == ("url_api" in after), "lock_key_changed")
    if "url_api" in after:
        old_api, api = (
            _string(p["url_api"], "lock_asset_mismatch") for p in (before, after)
        )
        left = _present(_MISE_ASSET.fullmatch(old_api), "lock_asset_mismatch")
        right = _present(_MISE_ASSET.fullmatch(api), "lock_asset_mismatch")
        _require(left[1] == right[1], "lock_key_changed")
        asset = evidence.record("asset", url_api=api)
        _require("browser_download_url" in asset, "fact_missing")
        _require(asset["browser_download_url"] == url, "lock_asset_mismatch")


def _mise_lock_source(text: str) -> dict[tuple[str, int, str, str], Statement]:
    fields: dict[tuple[str, int, str, str], Statement] = {}
    tools: Counter[str] = Counter()
    section: tuple[str, ...] = ()
    for statement in _toml_statements(text):
        if statement.text.startswith("["):
            section = _table(statement.text)
            if (
                len(section) == _PAIR_LENGTH
                and section[0] == "tools"
                and statement.text.startswith("[[")
            ):
                tools[section[1]] += 1
            continue
        if len(section) >= _PAIR_LENGTH and section[0] == "tools":
            _, tool, *suffix = section
            platform = ".".join(suffix).removeprefix("platforms.")
            key = next(iter(_toml(statement.text)))
            fields[tool, tools[tool] - 1, platform, key] = statement
    return fields


def _mise_projection(
    text: str,
    fields: dict[tuple[str, int, str, str], Statement],
    changed: set[tuple[str, int, str, str]],
) -> list[str]:
    hidden: set[int] = set()
    for key in sorted(changed):
        _require(key in fields, "lock_key_changed")
        statement = fields[key]
        hidden.update(range(statement.start, statement.end + 1))
    return [
        line
        for number, line in enumerate(_content_lines(text), 1)
        if number not in hidden
    ]


def _mise_lock(
    file: FilePatch,
    pins: dict[str, Change],
    facts: object,
) -> None:
    _require(pins, "lock_changed_without_pin")
    before, after = _toml(file.base), _toml(file.head)
    _require(_equal(_omit(before, "tools"), _omit(after, "tools")), "lock_key_changed")
    old_tools = _object(before.get("tools"), "lock_key_changed")
    new_tools = _object(after.get("tools"), "lock_key_changed")
    _require(old_tools.keys() == new_tools.keys(), "lock_key_changed")
    _require(pins.keys() <= new_tools.keys(), "lock_not_updated")
    old_spans, new_spans = _mise_lock_source(file.base), _mise_lock_source(file.head)
    fields = _MiseLockFields(file.path, facts, new_spans, set())
    for tool in sorted(new_tools):
        if _equal(old_tools[tool], new_tools[tool]):
            _require(tool not in pins, "lock_not_updated", tool)
            continue
        _require(tool in pins, "lock_changed_without_pin", tool)
        fields.tool(tool, pins[tool], old_tools[tool], new_tools[tool])
    _require(
        _mise_projection(file.base, old_spans, fields.changed)
        == _mise_projection(file.head, new_spans, fields.changed),
        "lock_key_changed",
        "change outside the pin's lock fields",
    )


@dataclass
class _MiseLockFields:
    path: str
    facts: object
    spans: dict[tuple[str, int, str, str], Statement]
    changed: set[tuple[str, int, str, str]]

    def tool(
        self,
        tool: str,
        change: Change,
        before: object,
        after: object,
    ) -> None:
        old = objects(before, "lock_key_changed")
        new = objects(after, "lock_key_changed")
        _require(len(old) == len(new), "lock_key_changed")
        affected = [
            index
            for index, entry in enumerate(old)
            if entry.get("version") == change.old
        ]
        _require(len(affected) == 1, "lock_version_mismatch", tool)
        index = affected[0]
        _require(
            _equal(old[:index] + old[index + 1 :], new[:index] + new[index + 1 :]),
            "lock_changed_without_pin",
        )
        old_entry, old_platforms = _platforms(old[index])
        new_entry, new_platforms = _platforms(new[index])
        _require(
            _equal(
                _omit(old_entry, *_MISE_VERSION_FIELDS),
                _omit(new_entry, *_MISE_VERSION_FIELDS),
            )
            and old_platforms.keys() == new_platforms.keys(),
            "lock_key_changed",
        )
        _require(
            new_entry.get("version") == change.new
            and new_entry.get("specifiers") == [change.new],
            "lock_version_mismatch",
            tool,
        )
        for key in _MISE_VERSION_FIELDS:
            if not _equal(old_entry.get(key), new_entry[key]):
                self.changed.add((tool, index, "", key))
        for platform in sorted(new_platforms):
            left = _object(old_platforms[platform], "lock_key_changed")
            right = _object(new_platforms[platform], "lock_key_changed")
            url_span = _present(
                self.spans.get((tool, index, platform, "url")), "lock_key_changed"
            )
            _mise_platform(
                left, right, change, Evidence(self.facts, self.path, url_span.start)
            )
            self.changed.update(
                (tool, index, platform, key)
                for key in _MISE_PLATFORM_FIELDS
                if not _equal(left.get(key), right.get(key))
            )


@dataclass
class Matches:
    metadata: dict[str, object]
    config: Config
    findings: list[Finding]
    bazel_pins: dict[str, Change]
    mise_pins: dict[str, Change]
    bazel_overrides: dict[str, str]

    def refuse(self, path: str, line: int, refusal: RefusalError) -> None:
        self.findings.append(Finding(refusal.code, path, line, refusal.detail))

    def evidence(self, path: str, line: int) -> Evidence:
        return Evidence(self.metadata.get("facts"), path, line)


def _pin(pins: dict[str, Change], name: str, change: Change) -> None:
    _require(name not in pins, "parse_doubt", name)
    pins[name] = change


@dataclass
class TextPins:
    file: FilePatch
    matches: Matches
    base: list[str]
    head: list[str]
    old_uses: set[int]
    new_uses: set[int]
    old_tools: dict[int, tuple[str, Slot]]
    new_tools: dict[int, tuple[str, Slot]]
    old_calls: dict[int, Call]
    new_calls: dict[int, Call]
    visited: set[int]

    def pair(self, old: int, new: int) -> None:
        kind = self.file.kind
        path = self.file.path
        evidence = self.matches.evidence(path, new)
        before, after = self.base[old - 1], self.head[new - 1]
        if kind == "workflow":
            _workflow_pair(
                before,
                after,
                scope=old in self.old_uses and new in self.new_uses,
                evidence=evidence,
                config=self.matches.config,
            )
        elif kind == "mise":
            key, change = _mise_pair(
                self.old_tools.get(old),
                self.new_tools.get(new),
                before,
                after,
                self.matches.config,
            )
            _pin(self.matches.mise_pins, key, change)
        else:
            self.starlark_pair(old, new, evidence)

    def starlark_pair(self, old: int, new: int, evidence: Evidence) -> None:
        before = _present(self.old_calls.get(old), "not_a_pin_line")
        after = _present(self.new_calls.get(new), "not_a_pin_line")
        name, left, right = _star_pair(
            before, after, (old, self.base[old - 1]), (new, self.head[new - 1])
        )
        config = self.matches.config
        # Every pair passed to this point has a call in both documents.
        if after.order in self.visited:
            return
        self.visited.add(after.order)
        if after.name == "bazel_dep":
            change = Change(left["version"].value, right["version"].value)
            _passed(bump(change.old, change.new, config.allowed))
            _pin(self.matches.bazel_pins, name, change)
        elif after.name == "git_override":
            _git_override(name, left, right, evidence, config)
        else:
            url = right[_one_slot(right, ("url", "urls"))]
            _archive(
                left, right, config, self.matches.evidence(self.file.path, url.line)
            )


def _text_file(file: FilePatch, matches: Matches) -> None:
    base, head = _content_lines(file.base), _content_lines(file.head)
    kind, path = file.kind, file.path
    pairs = TextPins(
        file,
        matches,
        base,
        head,
        _WorkflowYaml(path).scan(file.base) if kind == "workflow" else set(),
        _WorkflowYaml(path).scan(file.head) if kind == "workflow" else set(),
        _tool_slots(file.base) if kind == "mise" else {},
        _tool_slots(file.head) if kind == "mise" else {},
        _star_calls(file.base) if kind == "starlark" else {},
        _star_calls(file.head) if kind == "starlark" else {},
        set(),
    )
    if path == "MODULE.bazel":
        _bazel_overrides(pairs.old_calls, matches.bazel_overrides)
    for hunk in file.hunks:
        try:
            _counts(hunk)
        except RefusalError as refusal:
            matches.refuse(path, hunk.new, refusal)
            continue
        for old, new in hunk.pairs():
            try:
                pairs.pair(old, new)
            except RefusalError as refusal:
                matches.refuse(path, new, refusal)


def _bazel_overrides(calls: dict[int, Call], overrides: dict[str, str]) -> None:
    for line, call in calls.items():
        if line != call.start or call.name != "single_version_override":
            continue
        arguments = _arguments(call)
        if "version" not in arguments:
            continue
        module = _literal_slot(arguments.get("module_name", []), "module_name").value
        _require(module not in overrides)
        overrides[module] = _literal_slot(arguments["version"], "version").value


def _lock_file(file: FilePatch, matches: Matches) -> None:
    if file.kind == "bazel_lock":
        _bazel_lock(file, matches.bazel_pins, matches.config, matches.bazel_overrides)
    else:
        _require(
            matches.metadata.get("has_mise_lock") is not False or not matches.mise_pins
        )
        for hunk in file.hunks:
            _counts(hunk)
        _mise_lock(file, matches.mise_pins, matches.metadata.get("facts"))


def _missing_locks(matches: Matches, discovered: set[str]) -> None:
    if matches.bazel_pins and "MODULE.bazel.lock" not in discovered:
        matches.refuse("MODULE.bazel.lock", 0, RefusalError("lock_not_updated"))
    if matches.mise_pins:
        exists = matches.metadata.get("has_mise_lock")
        if type(exists) is not bool:
            matches.refuse(
                "mise.toml", 0, RefusalError("fact_missing", "has_mise_lock")
            )
        elif exists and "mise.lock" not in discovered:
            matches.refuse("mise.lock", 0, RefusalError("lock_not_updated"))


def match_patch(patch: str, metadata: dict[str, object]) -> list[Finding]:
    config = config_from(metadata)
    files = _strings(metadata.get("files"), "file_list_mismatch")
    _require(len(files) <= config.max_files, "too_many_files")
    sections = _patch_sections(patch)
    _require(len(sections) <= config.max_files, "too_many_files")
    parsed = [(_destination(section), section[1:]) for section in sections]
    paths = {path for path, _ in parsed}
    _require(
        len(paths) == len(parsed) == len(files) and paths == set(files),
        "file_list_mismatch",
    )
    _require(sections, "empty_diff")
    matches = Matches(metadata, config, [], {}, {}, {})
    locks = []
    for path, lines in sorted(parsed):
        try:
            file = _read_file(path, lines, metadata, config)
            if file.kind in _LOCKS:
                locks.append(file)
            else:
                _text_file(file, matches)
        except RefusalError as refusal:
            matches.refuse(path, 0, refusal)
    for file in locks:
        try:
            _lock_file(file, matches)
        except RefusalError as refusal:
            matches.refuse(file.path, file.hunks[0].new, refusal)
    _missing_locks(matches, paths)
    return sorted(matches.findings, key=lambda finding: (finding.path, finding.line))
