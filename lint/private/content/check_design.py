# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Check design directories and render their deterministic Markdown index."""

import argparse
import datetime as dt
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import cast
from urllib.parse import unquote, urlsplit

import yaml

ENCODING = "utf-8"
EMPTY_SECTION = (1, [])
EVIDENCE = re.compile(r"^(proven|existing|new|unverified)\b", re.IGNORECASE)
REQUIRED = (
    "type",
    "title",
    "description",
    "tags",
    "status",
    "owner",
    "updated",
    "decisions_open",
)
SECTIONS = (
    "Summary",
    "Decisions for tbhb",
    "Already decided",
    "Proposal",
    "How it works",
    "Risks and unknowns",
    "Plan",
)
SUMMARY_WORDS = 150
BULLETS = ("Recommendation", "Why", "If yes", "If no", "Reversible")
APPENDIX = re.compile(r"[A-Z]-[a-z0-9]+(?:-[a-z0-9]+)*\.md")
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---[ \t]*(?:\n|$)", re.DOTALL)
INLINE_CODE = re.compile(r"(`+)(?!`)(.*?)(?<!`)\1(?!`)", re.DOTALL)
LINK = re.compile(
    r"!?\[[^\]\n]*\]\(\s*(<[^>]*>|[^\s)]*)(?:\s+[^)]*)?\)|^ {0,3}\[[^\]]+\]:\s*(\S+)",
    re.MULTILINE,
)


def problem(path: Path, line: int, message: str) -> str:
    return f"{path.as_posix()}:{line}: {message}"


def read(path: Path) -> tuple[str, dict[str, object], list[str]]:
    try:
        text = path.read_text(encoding=ENCODING)
    except (OSError, UnicodeError) as error:
        return "", {}, [problem(path, 1, f"cannot read file: {error}")]
    match = FRONTMATTER.match(text)
    if match is None:
        return text, {}, [problem(path, 1, "missing frontmatter")]
    try:
        data: object = yaml.safe_load(match[1])
    except yaml.YAMLError:
        return text, {}, [problem(path, 2, "invalid YAML frontmatter")]
    if not isinstance(data, dict):
        return text, {}, [problem(path, 2, "frontmatter must be a mapping")]
    # A cast changes static types only, so mutating its annotation is equivalent.
    typed = cast("dict[str, object]", data)  # pragma: no mutate
    return text, typed, []


def prose(text: str, *, keep_comments: bool = False, keep_spans: bool = False) -> str:
    """Blank comments and code while preserving offsets and line numbers."""
    if not keep_comments:
        text = re.sub(r"<!--[\s\S]*?-->", lambda m: re.sub(r"[^\n]", " ", m[0]), text)
    lines = text.splitlines(keepends=True)
    fence: tuple[str, int] | None = None
    for i, line in enumerate(lines):
        marker = re.match(r" {0,3}((`|~)\2{2,})", line)
        if fence is not None:
            lines[i] = re.sub(r"[^\n]", " ", line)
            if marker and marker[2] == fence[0] and len(marker[1]) >= fence[1]:
                fence = None
        elif marker:
            fence = (marker[2], len(marker[1]))
            lines[i] = re.sub(r"[^\n]", " ", line)
    visible = "".join(lines)
    return (
        INLINE_CODE.sub(lambda m: re.sub(r"[^\n]", " ", m[0]), visible)
        if not keep_spans
        else visible
    )


def valid_tags(value: object) -> bool:
    if not isinstance(value, list):
        return False
    # Cast annotations have no runtime effect.
    items = cast("list[object]", value)  # pragma: no mutate
    return bool(items) and all(
        isinstance(item, str) and SLUG.fullmatch(item) for item in items
    )


def metadata(path: Path, data: dict[str, object]) -> list[str]:
    errors = [
        problem(path, 1, f"missing required frontmatter: {key}")
        for key in REQUIRED
        if key not in data
    ]
    for key in ("title", "description", "owner"):
        value = data.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(problem(path, 1, f"{key} must be a nonempty string"))
    if not valid_tags(data.get("tags")):
        errors.append(
            problem(path, 1, "tags must be a nonempty list of kebab-case words")
        )
    if data.get("status") not in ("draft", "decided", "superseded"):
        errors.append(problem(path, 1, "status must be draft, decided or superseded"))
    updated = str(data.get("updated"))
    try:
        dt.date.fromisoformat(updated)
    except ValueError:
        errors.append(problem(path, 1, "updated must be a YYYY-MM-DD date"))
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", updated):
        errors.append(problem(path, 1, "updated must use YYYY-MM-DD"))
    count = data.get("decisions_open")
    if type(count) is not int or count < 0:
        errors.append(problem(path, 1, "decisions_open must be a nonnegative integer"))
    return errors


def sections(path: Path, text: str, *, appendices: bool, max_lines: int) -> list[str]:
    errors = []
    original_lines = text.splitlines()
    text = prose(text, keep_spans=True)
    lines = text.splitlines()
    headings = [
        (i, line[3:]) for i, line in enumerate(lines, 1) if line.startswith("## ")
    ]
    expected = (*SECTIONS, "Appendices") if appendices else SECTIONS
    names = [name for _, name in headings]
    if names != list(expected):
        errors.append(problem(path, 1, "section order must be: " + ", ".join(expected)))
    status = re.search(
        r"^\|\s*Status\s*\|\s*Owner\s*\|\s*Updated\s*\|"
        r"\s*Needs from tbhb\s*\|\s*\n\|[ :|-]+\|\s*\n\|[^\n]+\|",
        text,
        re.MULTILINE,
    )
    if status is None or re.search(r"^## ", text[: status.start()], re.MULTILINE):
        errors.append(problem(path, 1, "status table must precede Summary"))
    bodies = {}
    for index, (line, name) in enumerate(headings):
        end = headings[index + 1][0] - 1 if index + 1 < len(headings) else len(lines)
        bodies[name] = (line, lines[line:end])
    summary_line, summary = bodies.get("Summary", EMPTY_SECTION)
    summary_words = " ".join(
        original_lines[summary_line : summary_line + len(summary)]
    ).split()
    if len(summary_words) > SUMMARY_WORDS:
        errors.append(problem(path, summary_line, "Summary exceeds 150 words"))
    if max_lines and len(lines) > max_lines:
        errors.append(problem(path, max_lines + 1, f"README exceeds {max_lines} lines"))
    decision_line, decisions = bodies.get("Decisions for tbhb", EMPTY_SECTION)
    errors.extend(check_decisions(path, decision_line, decisions))
    risk_line, risks = bodies.get("Risks and unknowns", EMPTY_SECTION)
    errors.extend(check_risks(path, risk_line, risks))
    return errors


def check_decisions(path: Path, decision_line: int, decisions: list[str]) -> list[str]:
    errors = []
    items = [
        (i, line)
        for i, line in enumerate(decisions)
        if re.match(r"^### D\d+\.\s", line)
    ]
    for index, (offset, _) in enumerate(items):
        end = items[index + 1][0] if index + 1 < len(items) else len(decisions)
        body = "\n".join(decisions[offset + 1 : end])
        errors.extend(
            problem(path, decision_line + offset + 1, f"D item missing {bullet} bullet")
            for bullet in BULLETS
            if not re.search(
                r"^[ \t]*[-*+] (?:\*\*)?" + bullet + r"(?::\*\*|\*\*:|:)[ \t]+\S",
                body,
                re.MULTILINE,
            )
        )
    return errors


def check_risks(path: Path, risk_line: int, risks: list[str]) -> list[str]:
    errors = []
    evidence_column = None
    for offset, row in enumerate(risks, 1):
        if not row.startswith("|"):
            continue
        cells = [cell.strip() for cell in re.split(r"(?<!\\)\|", row)]
        if "Evidence" in cells:
            evidence_column = cells.index("Evidence")
        elif re.fullmatch(r"[\s:|\-]+", row):
            continue
        elif (
            evidence_column is None
            or len(cells) <= evidence_column
            or not EVIDENCE.match(cells[evidence_column])
        ):
            errors.append(
                problem(
                    path,
                    risk_line + offset,
                    "Evidence must start with proven, existing, new or unverified",
                )
            )
    if evidence_column is None:
        errors.append(problem(path, risk_line, "Risks table needs an Evidence column"))
    return errors


def anchors(text: str) -> set[str]:
    """Collect GitHub-style ATX heading anchors, including duplicate headings."""
    found = set(re.findall(r'<a\s+(?:id|name)=["\']([^"\']+)', text))
    counts: dict[str, int] = {}
    for heading in re.findall(
        r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", prose(text, keep_spans=True), re.MULTILINE
    ):
        plain = re.sub(r"<[^>]*>", "", heading)
        slug = re.sub(r"[^\w -]", "", plain.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        found.add(f"{slug}-{count}" if count else slug)
    return found


def link_problem(target: Path, fragment: str, destination: str) -> str:
    if not target.exists():
        return f"relative link does not resolve: {destination}"
    if fragment and target.suffix == ".md":
        text, _, failures = read(target)
        # Linked Markdown need not have frontmatter; other read errors matter.
        if not text and failures:
            return f"cannot read relative link: {destination}"
        if unquote(fragment) not in anchors(text):
            return f"relative link anchor does not resolve: {destination}"
    return ""


def links(path: Path, text: str) -> tuple[set[Path], list[str]]:
    targets = set()
    errors = []
    for match in LINK.finditer(text):
        destination = (match[1] or match[2]).strip("<>")
        try:
            url = urlsplit(destination)
        except ValueError:
            errors.append(
                problem(
                    path,
                    text[: match.start()].count("\n") + 1,
                    "invalid link destination",
                )
            )
            continue
        if url.scheme or url.netloc:
            continue
        target = (
            (path.parent / unquote(url.path)).resolve() if url.path else path.resolve()
        )
        targets.add(target)
        message = link_problem(target, url.fragment, destination)
        if message:
            errors.append(problem(path, text[: match.start()].count("\n") + 1, message))
    return targets, errors


def check_terms(path: Path, text: str, forbidden_terms: list[str]) -> list[str]:
    visible = prose(text, keep_comments=True)
    return [
        problem(
            path, visible[: match.start()].count("\n") + 1, f"forbidden term: {term}"
        )
        for term in forbidden_terms
        for match in re.finditer(
            r"(?<!\w)" + re.escape(term) + r"(?!\w)", visible, re.IGNORECASE
        )
    ]


def check_directory(
    directory: Path, forbidden_terms: list[str], max_lines: int = 250
) -> list[str]:
    readme = directory / "README.md"
    files = sorted(directory.glob("*.md"))
    appendices = [path for path in files if path != readme]
    errors = []
    if not readme.is_file():
        errors.append(problem(readme, 1, "missing README.md"))
    targets_by_file = {}
    for path in files:
        text, data, failures = read(path)
        errors.extend(failures)
        clean = prose(text)
        targets, failures = links(path, clean)
        targets_by_file[path] = targets
        errors.extend(failures)
        expected_type = "Design Draft" if path == readme else "Design Appendix"
        if data.get("type") != expected_type:
            errors.append(problem(path, 1, f"type must be {expected_type}"))
        errors.extend(check_terms(path, text, forbidden_terms))
        if path == readme:
            errors.extend(
                check_readme(
                    path, text, data, appendices=bool(appendices), max_lines=max_lines
                )
            )
        else:
            errors.extend(check_appendix(path, data, targets))
    errors.extend(
        problem(readme, 1, f"README must link appendix {appendix.name}")
        for appendix in appendices
        if appendix.resolve() not in targets_by_file.get(readme, set())
    )
    return errors


def check_readme(
    path: Path, text: str, data: dict[str, object], *, appendices: bool, max_lines: int
) -> list[str]:
    clean = prose(text)
    errors = []
    errors.extend(metadata(path, data))
    errors.extend(
        sections(
            path,
            text,
            appendices=appendices,
            max_lines=max_lines,
        )
    )
    decisions = re.search(
        r"^## Decisions for tbhb\n(.*?)(?=^## |\Z)",
        clean,
        re.MULTILINE | re.DOTALL,
    )
    count = (
        len(re.findall(r"^### D\d+\.\s", decisions[1], re.MULTILINE))
        if decisions
        else 0
    )
    if data.get("decisions_open") != count:
        errors.append(problem(path, 1, f"decisions_open must equal {count} D headings"))
    return errors


def check_appendix(
    path: Path, data: dict[str, object], targets: set[Path]
) -> list[str]:
    readme = path.parent / "README.md"
    errors = []
    if not APPENDIX.fullmatch(path.name):
        errors.append(problem(path, 1, "appendix name must be [A-Z]-<kebab>.md"))
    if data.get("parent") != "README.md":
        errors.append(problem(path, 1, "appendix parent must be README.md"))
    if readme.resolve() not in targets:
        errors.append(problem(path, 1, "appendix needs a link back to README.md"))
    return errors


def check(root: Path, forbidden_terms: list[str], max_lines: int = 250) -> list[str]:
    directories = sorted(
        {
            path.parent
            for path in root.rglob("*.md")
            if path.name == "README.md"
            or read(path)[1].get("type") in ("Design Draft", "Design Appendix")
        }
    )
    if not directories:
        return [problem(root, 1, "no design directories found")]
    return [
        error
        for directory in directories
        for error in check_directory(directory, forbidden_terms, max_lines)
    ]


def cell(value: object) -> str:
    """Escape metadata for a single Markdown table cell."""
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace("|", "\\|")
        .replace("[", "\\[")
        .replace("]", "\\]")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\n", " ")
        .replace("\r", " ")
    )


def render_index(
    folder: Path, forbidden_terms: list[str], max_lines: int = 250
) -> tuple[str, list[str]]:
    rows = [
        "---",
        "type: Readme",
        "title: Designs",
        "description: Status and ownership of the designs in this directory.",
        "tags: [design]",
        "status: stable",
        "---",
        "",
        "# Designs",
        "",
        "| Title | Status | Owner | Decisions open | Updated |",
        "| --- | --- | --- | --- | --- |",
    ]
    errors = []
    if not folder.is_dir():
        return "", [problem(folder, 1, "missing designs directory")]
    for directory in sorted(folder.iterdir()):
        if directory.name == "README.md":
            continue
        if not directory.is_dir():
            errors.append(problem(directory, 1, "expected a design directory"))
            continue
        if not SLUG.fullmatch(directory.name):
            errors.append(problem(directory, 1, "design slug must be kebab case"))
        errors.extend(
            problem(child, 1, "design directories cannot hold subdirectories")
            for child in sorted(directory.iterdir())
            if child.is_dir()
        )
        failures = check_directory(directory, forbidden_terms, max_lines)
        errors.extend(failures)
        if failures:
            continue
        _, data, _ = read(directory / "README.md")
        title = cell(data["title"])
        values = " | ".join(
            cell(data[key]) for key in ("status", "owner", "decisions_open", "updated")
        )
        rows.append(f"| [{title}]({directory.name}/README.md) | {values} |")
    return "\n".join(rows) + "\n", errors


def index(
    root: Path, out: str, forbidden_terms: list[str], max_lines: int, *, write: bool
) -> list[str]:
    output = root / out
    if Path(out).anchor or ".." in Path(out).parts:
        return [problem(Path(out), 1, "index output must be a workspace-relative path")]
    rendered, errors = render_index(output.parent, forbidden_terms, max_lines)
    if errors:
        return errors
    if write:
        output.write_bytes(rendered.encode(ENCODING))
    elif not output.is_file() or output.read_bytes() != rendered.encode(ENCODING):
        return [problem(output, 1, "stale designs index; run the designs_index target")]
    return []


def generate(
    root: Path, manifest: Path, out: str, forbidden_terms: list[str], max_lines: int
) -> list[str]:
    """Read only declared source files, then write the validated index."""
    with tempfile.TemporaryDirectory() as temporary:
        tree = Path(temporary)
        for name in manifest.read_text(encoding=ENCODING).splitlines():
            destination = tree / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / name, destination)
        errors = index(tree, out, forbidden_terms, max_lines, write=True)
        if not errors:
            (root / out).write_bytes((tree / out).read_bytes())
        return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path())
    parser.add_argument("--forbidden-term", action="append", default=[])
    parser.add_argument(
        "--max-lines", type=int, default=250, help="README line limit; 0 disables it"
    )
    parser.add_argument("--index", help="index output, relative to root")
    parser.add_argument(
        "--manifest", type=Path, help="declared sources for the index writer"
    )
    args = parser.parse_args(argv)
    if args.manifest and not args.index:
        parser.error("--manifest requires --index")
    if args.manifest:
        errors = generate(
            args.root, args.manifest, args.index, args.forbidden_term, args.max_lines
        )
    elif args.index:
        errors = index(
            args.root,
            args.index,
            args.forbidden_term,
            args.max_lines,
            # False and None both select verification; other args remain mutated.
            write=False,  # pragma: no mutate
        )
    else:
        errors = check(args.root, args.forbidden_term, args.max_lines)
    for error in errors:
        print(error)
    if errors:
        return 1
    print("OK: designs conform" + (" and index is current" if args.index else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
