# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Check that relative and in-page links in tracked Markdown files resolve.

Usage: check_markdown_links.py ROOT [--git GIT]
ROOT may be a file in the repository root; a Bazel runfiles symlink to it
stands for the real directory. With --git the tracked files come from
`GIT ls-files` in ROOT; without it every file under ROOT counts as tracked
(for fixture trees). ROOT may hold a `.markdown-links.toml` of path-glob
exclusions, each with a reason. Problems print as `path:line: message`. Exit
0 when clean, 1 on problems, 2 when the check could not run.
"""

import argparse
import os
import posixpath
import re
import subprocess  # nosec B404
import sys
import tomllib
from pathlib import Path, PurePosixPath
from urllib.parse import unquote

CONFIG = ".markdown-links.toml"
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(`+)(?:(?!\1)[\s\S])+?\1(?!`)")
LINK = re.compile(
    r"\]\(\s*(<[^>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)"
    r"|^ {0,3}\[[^\]\n]+\]:[ \t]*(<[^>\n]*>|\S+)",
    re.MULTILINE,
)
SCHEME = re.compile(r"^(?:[A-Za-z][A-Za-z0-9+.-]*://|//|mailto:|tel:)", re.IGNORECASE)
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d{1,9}[.)])(?:\s|$)")
HEADING = re.compile(
    r"^ {0,3}#{1,6}(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"
    r"|^ {0,3}(\S[^\n]*)\n {0,3}(?:=+|-+)[ \t]*$",
    re.MULTILINE,
)
MARKUP = re.compile(r"!?\[([^\]]*)\]\([^)]*\)|[`*~]")
NOT_SLUG = re.compile(r"[^\w\- ]")
INDENTED = re.compile(r"^(?: {0,3}\t| {4})")
AFTER_BLANK = {
    "blank": "blank",
    "code": "gap",
    "gap": "gap",
    "list": "list_blank",
    "list_blank": "list_blank",
    "text": "blank",
}


class CheckError(Exception):
    """The check could not run."""


def blank(text: str) -> str:
    """Replace everything but newlines with spaces, to keep line numbers."""
    return re.sub(r"[^\n]", " ", text)


def blank_frontmatter(lines: list[str]) -> None:
    """Blank a leading frontmatter block in place."""
    if lines[0] == "---" and "---" in lines[1:]:
        end = lines.index("---", 1)
        lines[: end + 1] = [""] * (end + 1)


def closes_fence(line: str, fence: str) -> bool:
    bare = line.strip()
    return set(bare) == set(fence) and len(bare) >= len(fence)


def text_state(line: str, state: str) -> str:
    """The state after a non-blank line that opens or closes no block."""
    in_list = state in {"list", "list_blank"} and line[0].isspace()
    return "list" if LIST_ITEM.match(line) or in_list else "text"


def strip_blocks(text: str) -> str:
    """Blank frontmatter, fenced and indented code blocks, keeping line numbers."""
    lines = text.split("\n")
    blank_frontmatter(lines)
    fence: str | None = None
    # The kind of the last line: text, list (an item or its continuation),
    # code (an indented block), or blank after one of them.
    state = "blank"
    for index, line in enumerate(lines):
        if fence is not None:
            fence = None if closes_fence(line, fence) else fence
            lines[index] = ""
        elif not line.strip():
            state = AFTER_BLANK[state]
        elif INDENTED.match(line) and state in {"code", "gap", "blank"}:
            # An indented block cannot interrupt a paragraph or sit in a list.
            state = "code"
            lines[index] = ""
        elif match := FENCE.match(line):
            fence = match[1]
            state = "blank"
            lines[index] = ""
        else:
            state = text_state(line, state)
    return "\n".join(lines)


def strip_code(text: str) -> str:
    """Also blank code spans."""
    return CODE_SPAN.sub(lambda m: blank(m[0]), strip_blocks(text))


def slug(heading: str) -> str:
    plain = MARKUP.sub(lambda m: m[1] or "", heading).strip().lower()
    return NOT_SLUG.sub("", plain).replace(" ", "-")


def anchors(text: str) -> set[str]:
    """The GitHub heading anchors of a file, numbering repeats."""
    found: set[str] = set()
    seen: dict[str, int] = {}
    for match in HEADING.finditer(strip_blocks(text)):
        base = slug(match[1] or match[2] or "")
        count = seen.get(base, 0)
        seen[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    return found


def destinations(text: str) -> list[tuple[int, str]]:
    """Each link destination with its 1-based line."""
    stripped = strip_code(text)
    return [
        (
            stripped[: match.start()].count("\n") + 1,
            (match[1] or match[2] or "").strip("<>"),
        )
        for match in LINK.finditer(stripped)
    ]


def parents(files: set[str]) -> set[str]:
    return {
        parent.as_posix() for file in files for parent in PurePosixPath(file).parents
    }


def page_problem(fragment: str, page: set[str]) -> str | None:
    if fragment and fragment.lower() not in page:
        return f"#{fragment} matches no heading in this file"
    return None


def link_problem(
    source: str, dest: str, tracked: set[str], page: set[str]
) -> str | None:
    """Why a destination fails to resolve, or None when it resolves."""
    if SCHEME.match(dest):
        return None
    # Split at the raw `#` and `?`, then decode: `%23` and `%3F` stay in names.
    target, _, fragment = dest.partition("#")
    target, fragment = unquote(target.partition("?")[0]), unquote(fragment)
    if not target:
        return page_problem(fragment, page)
    if fragment:
        return f"{dest} has a fragment on a link to another file: link to the file"
    base = posixpath.dirname(source) if not target.startswith("/") else ""
    path = posixpath.normpath(posixpath.join(base, target.lstrip("/")))
    if path == ".." or path.startswith("../"):
        return f"{dest} points outside the repository"
    if path not in tracked:
        return f"{dest} is not a tracked file or directory"
    return None


def load_exclusions(root: Path) -> list[tuple[str, int]]:
    """Each glob with the line of its [[exclude]] table."""
    path = root / CONFIG
    if not path.exists():
        return []
    text = path.read_text()
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        message = f"{CONFIG}: {error}"
        raise CheckError(message) from error
    headers = [
        number
        for number, line in enumerate(text.split("\n"), 1)
        if line.strip() == "[[exclude]]"
    ]
    entries: list[dict[str, object]] = data.get("exclude", [])
    if (
        set(data) - {"exclude"}
        or not isinstance(entries, list)
        or len(entries) != len(headers)
    ):
        message = f"{CONFIG}: hold only [[exclude]] tables, one per exclusion"
        raise CheckError(message)
    out = []
    for index, entry in enumerate(entries):
        line = headers[index]
        glob, reason = entry.get("glob"), entry.get("reason")
        if set(entry) != {"glob", "reason"}:
            message = f"{CONFIG}:{line}: an exclusion has only glob and reason"
            raise CheckError(message)
        if not isinstance(glob, str) or not glob.strip():
            message = f"{CONFIG}:{line}: glob must be a non-blank string"
            raise CheckError(message)
        if not isinstance(reason, str) or not reason.strip():
            message = f"{CONFIG}:{line}: {glob} needs a non-blank reason"
            raise CheckError(message)
        out.append((glob, line))
    return out


def tracked_files(root: Path, git: str | None) -> set[str]:
    if git is None:
        return {
            Path(directory, name).relative_to(root).as_posix()
            for directory, _, names in os.walk(root)
            for name in names
        }
    # B404 and B603 on the import and call: the check runs the git it is
    # given, with a fixed argument list and no shell.
    try:
        run = subprocess.run(  # noqa: S603  # nosec B603
            [git, "ls-files", "-z"],
            cwd=root,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        message = f"git ls-files failed: {error}"
        raise CheckError(message) from error
    return {name for name in run.stdout.decode().split("\0") if name}


def file_errors(
    root: Path,
    source: str,
    tracked: set[str],
    exclusions: list[tuple[str, int]],
    used: set[str],
) -> list[str]:
    """The problems in one Markdown file; adds each exclusion it uses to used."""
    text = (root / source).read_text()
    page = anchors(text)
    errors = []
    for line, dest in destinations(text):
        problem = link_problem(source, dest, tracked, page)
        if problem is None:
            continue
        hits = [g for g, _ in exclusions if PurePosixPath(source).full_match(g)]
        used.update(hits)
        if not hits:
            errors.append(f"{source}:{line}: {problem}")
    return errors


def check(root: Path, git: str | None = None) -> list[str]:
    if not root.is_dir():
        message = f"{root} is not a directory"
        raise CheckError(message)
    exclusions = load_exclusions(root)
    files = tracked_files(root, git)
    tracked = files | parents(files)
    used: set[str] = set()
    errors: list[str] = []
    sources = sorted(name for name in files if name.endswith(".md"))
    if not sources:
        # A scan of nothing proves nothing: this covers an empty tree, an
        # empty `git ls-files` and a tree with no Markdown.
        return [f"{root}: no tracked Markdown files to check"]
    for source in sources:
        errors += file_errors(root, source, tracked, exclusions, used)
    errors += [
        f"{CONFIG}:{line}: exclusion {glob} matches no failing link"
        for glob, line in exclusions
        if glob not in used
    ]
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--git")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if root.is_file():
        root = root.parent
    git = args.git
    if git and not Path(git).is_absolute() and "TEST_SRCDIR" in os.environ:
        git = str(Path(os.environ["TEST_SRCDIR"], git))
    try:
        errors = check(root, git)
    except (CheckError, OSError) as error:
        sys.stderr.write(f"check_markdown_links: {error}\n")
        return 2
    sys.stdout.write("".join(f"{error}\n" for error in errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
