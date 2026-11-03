# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
"""Check the docs bundle and the repository's Markdown frontmatter.

Usage: uv run python tools/check_docs.py [ROOT]

ROOT defaults to the current directory. Two checks run, and every failure is
printed as `path: problem` before the script exits 1.

The bundle check covers ROOT/docs as an OKF v0.2 bundle. Every Markdown file
other than index.md needs frontmatter that validates against
docs/schemas/frontmatter.schema.json. The bundle-root index.md carries only
`okf_version` (docs/schemas/index-frontmatter.schema.json), any other index.md
carries no frontmatter, an index entry reads `* [Title](link) - description`,
every document is listed by some index.md, and each path segment is a valid
OKF concept ID.

The repository check applies the document schema to every other Markdown file
git tracks or would track, skipping hidden directories. Files at the repository
root and agent instruction files (AGENTS.md, CLAUDE.md) anywhere, including in
the bundle, must have no frontmatter and are not OKF documents.

Standard tools cover the rest: rumdl checks that relative links resolve, and
no standard tool validates Markdown frontmatter against a JSON Schema.
"""

import argparse
import json
import re
import subprocess  # nosec B404
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError

# Names live at module level, where mutmut leaves them alone: a mutated case
# (INDEX.MD, GIT) still resolves on a case-insensitive filesystem, so no test
# could tell it from the original there.
GIT = "git"
# The body returned with a failed read; callers ignore it.
NO_BODY = ""
INDEX = "index.md"
# Agent instruction files are read verbatim by the harnesses wherever they sit,
# so they are never OKF documents and carry no frontmatter.
AGENT_FILES = frozenset({"AGENTS.md", "CLAUDE.md"})
SCHEMAS = Path("docs") / "schemas"
DOC_SCHEMA = "frontmatter.schema.json"
INDEX_SCHEMA = "index-frontmatter.schema.json"
SEGMENT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
INDEX_ENTRY = re.compile(r"\* \[[^\]]+\]\((?P<link>[^)\s#]+)\) - \S.*")
FRONTMATTER = re.compile(r"---\n(?P<yaml>.*?)^---[ \t]*$\n?", re.DOTALL | re.MULTILINE)


class FrontmatterError(ValueError):
    """The frontmatter block cannot be read."""


def _keep_text(loader: yaml.SafeLoader, node: yaml.Node) -> str:
    """Construct a timestamp as the text the author wrote."""
    return loader.construct_scalar(node)  # pyrefly: ignore[bad-argument-type]


class _Loader(yaml.SafeLoader):
    """SafeLoader that keeps timestamps as text, so the schema can check them."""


_Loader.add_constructor("tag:yaml.org,2002:timestamp", _keep_text)


def parse(text: str) -> tuple[object, str]:
    """Split a file into its parsed frontmatter and body.

    The frontmatter is None when the file has none or its block is empty.

    Raises:
        FrontmatterError: The block is unterminated or is not valid YAML.
    """
    match = FRONTMATTER.match(text)
    if match is None:
        if text.startswith("---\n"):
            message = "unterminated frontmatter"
            raise FrontmatterError(message)
        return None, text
    try:
        # _Loader is a SafeLoader.
        data: object = yaml.load(match["yaml"], Loader=_Loader)  # noqa: S506  # nosec B506
    except yaml.YAMLError as exc:
        message = f"invalid YAML: {' '.join(str(exc).split())}"
        raise FrontmatterError(message) from exc
    return data, text[match.end() :]


def load_validator(path: Path) -> Draft202012Validator:
    """Load a schema, check it against the 2020-12 meta-schema, and build a validator.

    Raises:
        SchemaError: The schema is not a valid 2020-12 schema.
    """
    # UTF-8 is the default encoding since Python 3.15 (PEP 686).
    schema = json.loads(path.read_text())
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(
        schema, format_checker=Draft202012Validator.FORMAT_CHECKER
    )


def problems(data: object, validator: Draft202012Validator) -> list[str]:
    """Return one line per way the frontmatter breaks the schema."""
    if data is None:
        return ["no frontmatter"]
    found = sorted(validator.iter_errors(data), key=lambda error: error.json_path)
    return [f"{error.json_path}: {error.message}" for error in found]


def _read(path: Path, rel: Path) -> tuple[object, str, list[str]]:
    """Parse a file, reporting an unreadable block as an error line."""
    try:
        data, body = parse(path.read_text())
    except FrontmatterError as exc:
        return None, NO_BODY, [f"{rel}: {exc}"]
    return data, body, []


def _bare(path: Path, rel: Path) -> list[str]:
    """Report frontmatter on a file that must have none."""
    if path.read_text().startswith("---\n"):
        return [f"{rel}: must have no frontmatter"]
    return []


def _check_index(  # noqa: PLR0913  # one call site; the pieces come from the walk
    rel: Path,
    *,
    is_root: bool,
    data: object,
    body: str,
    validator: Draft202012Validator,
    listed: set[Path],
    folder: Path,
) -> list[str]:
    """Check an index.md and record the files its entries list."""
    errors: list[str]
    if is_root:
        errors = [f"{rel}: {line}" for line in problems(data, validator)]
    elif data is None:
        errors = []
    else:
        errors = [f"{rel}: index.md must have no frontmatter"]
    for line in body.splitlines():
        if not line.startswith("* "):
            continue
        entry = INDEX_ENTRY.fullmatch(line)
        if entry is None:
            errors.append(f"{rel}: malformed index entry: {line}")
        else:
            listed.add((folder / entry["link"]).resolve())
    return errors


def check_bundle(
    root: Path, doc: Draft202012Validator, index: Draft202012Validator
) -> list[str]:
    """Check ROOT/docs as an OKF bundle."""
    bundle = root / "docs"
    errors: list[str] = []
    if not (bundle / INDEX).is_file():
        errors.append("docs/index.md: missing bundle-root index")
    listed: set[Path] = set()
    documents: list[tuple[Path, Path]] = []
    for path in sorted(bundle.rglob("*.md")):
        rel = path.relative_to(root)
        if path.name in AGENT_FILES:
            errors.extend(_bare(path, rel))
            continue
        errors.extend(
            f"{rel}: invalid concept id segment {part!r}"
            for part in path.relative_to(bundle).with_suffix("").parts
            if not SEGMENT.fullmatch(part)
        )
        data, body, failed = _read(path, rel)
        errors.extend(failed)
        if failed:
            continue
        if path.name == INDEX:
            errors.extend(
                _check_index(
                    rel,
                    is_root=path.parent == bundle,
                    data=data,
                    body=body,
                    validator=index,
                    listed=listed,
                    folder=path.parent,
                )
            )
            continue
        documents.append((path, rel))
        errors.extend(f"{rel}: {line}" for line in problems(data, doc))
    errors.extend(
        f"{rel}: not listed in any index.md"
        for path, rel in documents
        if path.resolve() not in listed
    )
    return errors


def repo_markdown(root: Path) -> list[Path]:
    """List Markdown files git tracks or would track, outside docs/ and hidden dirs.

    ``testdata`` directories are left out too: they hold fixtures, which are
    content under test rather than documents, as in Go's tooling.
    """
    # Fixed argv; git comes from the pinned toolchain.
    listing = subprocess.run(  # nosec B603
        [
            GIT,
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
            "*.md",
        ],
        capture_output=True,
        check=True,
        text=True,
    ).stdout
    names = [Path(name) for name in sorted(listing.split("\0")) if name]
    return [
        root / name
        for name in names
        if name.parts[0] != "docs"
        and not any(part.startswith(".") or part == "testdata" for part in name.parts)
        and (root / name).is_file()
    ]


def check_repo(root: Path, doc: Draft202012Validator) -> list[str]:
    """Check the frontmatter of every Markdown file outside the bundle.

    Files at the repository root (README.md and the like) and agent instruction
    files anywhere (AGENTS.md, CLAUDE.md) are the exception: GitHub and the
    harnesses read them verbatim, so they must have no frontmatter at all.
    """
    errors: list[str] = []
    for path in repo_markdown(root):
        rel = path.relative_to(root)
        if len(rel.parts) == 1 or path.name in AGENT_FILES:
            errors.extend(_bare(path, rel))
            continue
        data, _, failed = _read(path, rel)
        errors.extend(failed)
        if not failed:
            errors.extend(f"{rel}: {line}" for line in problems(data, doc))
    return errors


def main(argv: list[str] | None = None) -> int:
    """Run both checks over ROOT and report."""
    parser = argparse.ArgumentParser(description="Check docs and Markdown frontmatter.")
    parser.add_argument("root", nargs="?", type=Path, default=Path())
    root: Path = parser.parse_args(argv).root
    try:
        doc = load_validator(root / SCHEMAS / DOC_SCHEMA)
        index = load_validator(root / SCHEMAS / INDEX_SCHEMA)
    except SchemaError as exc:
        print(f"invalid schema: {exc.message}")
        return 1
    errors = check_bundle(root, doc, index) + check_repo(root, doc)
    for error in errors:
        print(error)
    if errors:
        return 1
    print("OK: docs bundle and repository frontmatter conform")
    return 0


if __name__ == "__main__":
    sys.exit(main())
