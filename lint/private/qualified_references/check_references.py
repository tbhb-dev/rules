# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Check issue and pull request references in prose."""

import argparse
import os
import re
import subprocess  # nosec B404 - Git reads local revisions without a shell.
import sys
from itertools import pairwise
from typing import TYPE_CHECKING

from markdown_it import MarkdownIt

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator

    from markdown_it.token import Token

MARKDOWN = MarkdownIt("commonmark", {"linkify": True}).enable("linkify")
REFERENCE = re.compile(
    r"(?P<repo>(?<![\w./-])[A-Za-z0-9][A-Za-z0-9-]*/[\w.-]+)?"
    r"(?P<number>(?<![#\x00])#[0-9]+)(?![\w#-])"
)
RELATIVE_URL = re.compile(
    r"(?<![\w/])(?:(?:\.\.?/|/|doi:)[^\s<>\x00]+|"
    r"[\w./-]+\.(?:md|markdown|html?))#[^\s<>\x00]+",
    re.IGNORECASE,
)
COLOR_LENGTHS = {4, 5, 7, 9}  # Includes the leading hash.
ISSUE_CUE = re.compile(
    r"\b(?:issues?|prs?|pull requests?|see|refs?|references?|fix(?:es|ed)?|"
    r"clos(?:e|es|ed)|resolv(?:e|es|ed)|tracks?|related to)[ \t]*(?:[:(][ \t]*)?$",
    re.IGNORECASE,
)
ANCHOR_CUE = re.compile(r"\banchors?[ \t]+$", re.IGNORECASE)
HTML_CODE = re.compile(r"<(/?)code(?=[\s>])", re.IGNORECASE)
MERGE_TITLE = re.compile(r"Merge pull request #[0-9]+(?: from \S+)?")
SQUASH_SUFFIX = re.compile(r" \(#[0-9]+\)$")


def inline_prose(children: list[Token]) -> str:
    """Keep visible text, including ordinary link labels."""
    parts: list[str] = []
    auto_link = False
    anchor = None
    html_code = False
    for child in children:
        if child.type == "link_open":
            auto_link = child.info == "auto"
            href = child.attrGet("href") or ""
            _, separator, fragment = href.rpartition("#")
            anchor = separator + fragment if separator else None
        elif child.type == "link_close":
            auto_link = False
            anchor = None
        elif child.type == "html_inline":
            tag = HTML_CODE.match(child.content)
            if tag:
                html_code = not (tag[1] or child.content.endswith("/>"))
                parts.append(" ")
        elif child.type in {"hardbreak", "softbreak"}:
            parts.append("\n")
        elif child.type in {"code_inline", "image"}:
            parts.append(" ")
        elif child.type == "text":
            if auto_link:
                # Linkify stops at the address in mailto URLs. A contiguous
                # fragment still belongs to the URL.
                parts.append("\0")
            elif html_code or child.content == anchor:
                parts.append(" ")
            else:
                parts.append(child.content)
    return "".join(parts)


def bare_references(text: str) -> Iterator[tuple[int, str]]:
    """Yield the source block's first line and each bare reference in it."""
    tokens = MARKDOWN.parse(text)
    for opening, block in pairwise(tokens):
        if opening.type != "paragraph_open" or block.map is None:
            continue
        prose = RELATIVE_URL.sub(" ", inline_prose(block.children or []))
        for match in REFERENCE.finditer(prose):
            number = match["number"]
            prefix = prose[: match.start()]
            if match["repo"] or ANCHOR_CUE.search(prefix):
                continue
            # An all-digit hex color and an issue number can look identical.
            # Require an issue cue for the four overlapping token lengths.
            if len(number) in COLOR_LENGTHS and not ISSUE_CUE.search(prefix):
                continue
            yield block.map[0] + 1, number


def text_findings(kind: str, text: str) -> Iterator[tuple[str, str]]:
    title, _, body = text.partition("\n")
    if kind == "commit":
        if MERGE_TITLE.fullmatch(title):
            title = ""
        title = SQUASH_SUFFIX.sub("", title)
    yield from (("title", number) for _, number in bare_references(title))
    yield from (
        (f"body:{line}", number)
        for line, number in bare_references(body.removeprefix("\n"))
    )


def git(*args: str) -> bytes:
    return subprocess.check_output(  # noqa: S603
        ["git", *args],  # noqa: S607
        cwd=os.environ.get("BUILD_WORKSPACE_DIRECTORY"),
    )  # nosec B603 B607 - Workflow supplies revisions, never shell commands.


def revision(ref: str) -> str:
    return (
        git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")
        .decode()
        .strip()
    )


def docs_findings(base: str | None, head: str) -> Iterator[tuple[str, str]]:
    head = revision(head)
    changed = None
    if base is not None:
        changed = set(
            git(
                "diff",
                "--name-only",
                "--no-renames",
                "--no-relative",
                "-z",
                f"{revision(base)}...{head}",
                "--",
            ).split(b"\0")
        )
    tree = git("ls-tree", "-rz", "--full-tree", head)
    for entry in tree.split(b"\0")[:-1]:
        metadata, path = entry.split(b"\t", 1)
        if changed is not None and path not in changed:
            continue
        mode, _, oid = metadata.split()
        if (
            mode not in {b"100644", b"100755"}
            or not path.lower().endswith((b".md", b".markdown"))
            or b"testdata" in path.split(b"/")[:-1]
        ):
            continue
        name = (
            path.decode(errors="backslashreplace")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
        )
        doc = git("cat-file", "blob", oid.decode()).decode(errors="replace")
        yield from ((f"{name}:{line}", number) for line, number in bare_references(doc))


def report(findings: Iterable[tuple[str, str]], *, mode: str) -> int:
    failed = False
    for location, number in findings:
        print(f"{mode}: {location}: qualify {number} as owner/repo{number}")
        failed = True
    return int(failed and mode == "fail")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="kind", required=True)
    commands.add_parser("pr-text", help="read a pull request title and body on stdin")
    commands.add_parser("commit", help="read a commit message on stdin")
    docs = commands.add_parser("docs", help="read tracked Markdown at a Git revision")
    docs.add_argument(
        "--base", help="limit the check to files changed since the merge base"
    )
    docs.add_argument("--head", default="HEAD")
    docs.add_argument("--mode", choices=("warn", "fail"))
    args = parser.parse_args(argv)
    if args.kind != "docs":
        return report(text_findings(args.kind, sys.stdin.read()), mode="fail")
    try:
        mode = args.mode or ("fail" if args.base is not None else "warn")
        return report(docs_findings(args.base, args.head), mode=mode)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"qualified_references: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
