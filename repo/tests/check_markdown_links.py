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
import subprocess
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
SCHEME = re.compile(r"^(?:[A-Za-z][A-Za-z0-9+.-]*:|//)")
ATX = re.compile(r"^ {0,3}#{1,6}(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
MARKUP = re.compile(r"!?\[([^\]]*)\]\([^)]*\)|[`*~]")
UNSLUG = re.compile(r"[^\w\- ]")


class CheckError(Exception):
    """The check could not run."""


def blank(text: str) -> str:
    """Replace everything but newlines with spaces, to keep line numbers."""
    return re.sub(r"[^\n]", " ", text)


def strip_blocks(text: str) -> str:
    """Blank frontmatter and fenced blocks, keeping line numbers."""
    lines = text.split("\n")
    if lines[0] == "---" and "---" in lines[1:]:
        end = lines.index("---", 1)
        lines[: end + 1] = [""] * (end + 1)
    fence = ""
    for index, line in enumerate(lines):
        match = FENCE.match(line)
        if fence:
            closes = match and match[1][0] == fence[0] and len(match[1]) >= len(fence)
            fence = "" if closes else fence
            lines[index] = ""
        elif match:
            fence = match[1]
            lines[index] = ""
    return "\n".join(lines)


def strip_code(text: str) -> str:
    """Also blank code spans."""
    return CODE_SPAN.sub(lambda m: blank(m[0]), strip_blocks(text))


def slug(heading: str) -> str:
    plain = MARKUP.sub(lambda m: m[1] or "", heading).strip().lower()
    return UNSLUG.sub("", plain).replace(" ", "-")


def anchors(text: str) -> set[str]:
    """The GitHub heading anchors of a file, numbering repeats."""
    found: set[str] = set()
    seen: dict[str, int] = {}
    lines = strip_blocks(text).split("\n")
    for index, line in enumerate(lines):
        atx = ATX.match(line)
        setext = (
            line.strip()
            and index + 1 < len(lines)
            and SETEXT.match(lines[index + 1])
            and not ATX.match(line)
        )
        if not atx and not setext:
            continue
        base = slug(atx[1] or "" if atx else line)
        count = seen.get(base, 0)
        seen[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    return found


def destinations(text: str) -> list[tuple[int, str]]:
    """Each link destination with its 1-based line."""
    stripped = strip_code(text)
    return [
        (
            stripped.count("\n", 0, match.start()) + 1,
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
    target, _, fragment = unquote(dest).partition("#")
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
        entries = tomllib.loads(text).get("exclude", [])
    except tomllib.TOMLDecodeError as error:
        message = f"{CONFIG}: {error}"
        raise CheckError(message) from error
    headers = [
        number
        for number, line in enumerate(text.split("\n"), 1)
        if line.strip() == "[[exclude]]"
    ]
    out = []
    for entry, line in zip(entries, headers, strict=True):
        glob, reason = entry.get("glob"), entry.get("reason")
        if set(entry) != {"glob", "reason"}:
            message = f"{CONFIG}:{line}: an exclusion has only glob and reason"
            raise CheckError(message)
        if not isinstance(glob, str) or not glob.strip():
            message = f"{CONFIG}:{line}: glob must be a nonblank string"
            raise CheckError(message)
        if not isinstance(reason, str) or not reason.strip():
            message = f"{CONFIG}:{line}: {glob} needs a nonblank reason"
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
    try:
        run = subprocess.run(  # noqa: S603 -- Fixed argument list.
            [git, "ls-files", "-z"],
            cwd=root,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        message = f"git ls-files failed: {error}"
        raise CheckError(message) from error
    return {name for name in run.stdout.decode().split("\0") if name}


def check(root: Path, git: str | None = None) -> list[str]:
    if not root.is_dir():
        message = f"{root} is not a directory"
        raise CheckError(message)
    exclusions = load_exclusions(root)
    files = tracked_files(root, git)
    tracked = files | parents(files)
    used: set[str] = set()
    errors: list[str] = []
    for source in sorted(name for name in files if name.endswith(".md")):
        text = (root / source).read_text()
        page = anchors(text)
        for line, dest in destinations(text):
            problem = link_problem(source, dest, tracked, page)
            if problem is None:
                continue
            hits = [g for g, _ in exclusions if PurePosixPath(source).full_match(g)]
            used.update(hits)
            if not hits:
                errors.append(f"{source}:{line}: {problem}")
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
