# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Report changes to review controls without making them a merge gate."""

import argparse
import ast
import difflib
import json
import os
import re
import subprocess  # nosec B404  # Only the pinned Git executable is launched.
from pathlib import Path
from typing import NotRequired, TypedDict, cast
lazy from collections.abc import Iterator


class Category(TypedDict):
    name: str
    paths: list[str]
    exclude_paths: NotRequired[list[str]]
    added: NotRequired[list[str]]
    sections: NotRequired[str]
    removed_test_calls: NotRequired[str]
    test_attributes: NotRequired[list[str]]


class Hit(TypedDict):
    path: str
    categories: list[str]


class Report(TypedDict):
    files: list[Hit]
    categories: list[str]
    error: str | None


def git(executable: str, *args: str) -> str:
    return subprocess.run(  # nosec B603  # Arguments are passed without a shell.
        [executable, *args],
        check=True,
        capture_output=True,
    ).stdout.decode("utf-8", errors="surrogateescape")


def added_lines(before: str, after: str) -> str:
    old, new = before.splitlines(), after.splitlines()
    matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
    return "\n".join(
        line
        for operation, _, _, start, end in matcher.get_opcodes()
        if operation in {"insert", "replace"}
        for line in new[start:end]
    )


def sections(text: str, pattern: str) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    current = ""
    for line in text.splitlines():
        if header := re.match(r"^\s*\[([^]]+)\]", line):
            current = header[1].replace('"', "").replace("'", "")
        if re.search(pattern, current):
            found.setdefault(current, []).append(line)
    return found


def source_entries(
    node: ast.AST, bindings: dict[str, ast.expr], seen: frozenset[str] = frozenset()
) -> set[str]:
    parts = list(ast.walk(node))
    entries = {
        ast.dump(part)
        for part in parts
        if isinstance(part, (ast.Constant, ast.Name, ast.Attribute))
    }
    for part in parts:
        if isinstance(part, ast.Name) and part.id in bindings and part.id not in seen:
            entries |= source_entries(bindings[part.id], bindings, seen | {part.id})
    return entries


def called_test(node: ast.AST, pattern: str) -> bool:
    if not isinstance(node, ast.Call):
        return False
    function = node.func
    if isinstance(function, ast.Name):
        return re.search(pattern, function.id) is not None
    if isinstance(function, ast.Attribute):
        return re.search(pattern, function.attr) is not None
    return False


def test_inventory(
    text: str, pattern: str, attributes: list[str]
) -> dict[str, set[str]]:
    """Read literal test names and source expressions without evaluating BUILD."""
    tree = ast.parse(text)
    bindings = {
        target.id: statement.value
        for statement in tree.body
        if isinstance(statement, ast.Assign)
        for target in statement.targets
        if isinstance(target, ast.Name)
    }
    inventory: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if not called_test(node, pattern):
            continue
        node = cast("ast.Call", node)
        keywords = {keyword.arg: keyword.value for keyword in node.keywords}
        name = keywords.get("name")
        if not isinstance(name, ast.Constant) or not isinstance(name.value, str):
            continue
        inventory[name.value] = set().union(
            *(
                source_entries(value, bindings)
                for key, value in keywords.items()
                if key in attributes
            )
        )
    return inventory


def tests_removed(
    before: str, after: str, removed_test_calls: str, test_attributes: list[str]
) -> bool:
    try:
        old = test_inventory(before, removed_test_calls, test_attributes)
        new = test_inventory(after, removed_test_calls, test_attributes)
    except SyntaxError:
        # Unsupported BUILD syntax deserves review rather than a silent miss.
        return True
    return any(name not in new or not srcs <= new[name] for name, srcs in old.items())


def matches(category: Category, path: str, before: str, after: str) -> bool:
    exclude_paths = category.get("exclude_paths", [])
    if any(re.search(pattern, path) for pattern in exclude_paths):
        return False
    if any(re.search(pattern, path) for pattern in category["paths"]):
        return True
    if any(
        re.search(pattern, added_lines(before, after))
        for pattern in category.get("added", [])
    ):
        return True
    if Path(path).name == "pyproject.toml" and "sections" in category:
        return sections(before, category["sections"]) != sections(
            after, category["sections"]
        )
    if Path(path).name in {"BUILD", "BUILD.bazel"} and "removed_test_calls" in category:
        return tests_removed(
            before,
            after,
            category["removed_test_calls"],
            category.get("test_attributes", ["srcs"]),
        )
    return False


def changed_blobs(
    executable: str, base: str, head: str
) -> Iterator[tuple[str, str, str]]:
    records = iter(
        git(
            executable,
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-relative",
            "--no-color",
            "--find-renames",
            "-l0",
            "--ignore-submodules=all",
            "--raw",
            "--no-abbrev",
            "-z",
            base,
            head,
            "--",
        ).split("\0")[:-1]
    )
    for header in records:
        _, _, old, new, status = header.split()
        path = next(records)
        if status.startswith("R"):
            # The former path still gets path-based review, but moving a
            # file adds no pragmas. Content changes belong to its new path.
            yield path, old, old
            path = next(records)
        yield path, old, new


def detect(executable: str, base: str, head: str, categories: list[Category]) -> Report:
    base, head = (
        git(
            executable, "rev-parse", "--verify", "--end-of-options", rev + "^{commit}"
        ).strip()
        for rev in (base, head)
    )
    files: list[Hit] = []
    for path, old, new in changed_blobs(executable, base, head):
        before, after = (
            "" if set(oid) == {"0"} else git(executable, "cat-file", "blob", oid)
            for oid in (old, new)
        )
        names = sorted(c["name"] for c in categories if matches(c, path, before, after))
        if names:
            files.append({"path": path, "categories": names})
    files.sort(key=lambda hit: hit["path"])
    return {
        "files": files,
        "categories": sorted({name for hit in files for name in hit["categories"]}),
        "error": None,
    }


def lines(report: Report) -> list[str]:
    if report["error"]:
        return ["controls_changed: unavailable: " + report["error"]]
    return [
        json.dumps(hit["path"]) + "\t" + ",".join(hit["categories"])
        for hit in report["files"]
    ] + [
        (
            f"controls_changed: {len(report['files'])} paths, "
            f"{len(report['categories'])} categories"
        )
    ]


def escape_annotation(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def github_output(report: Report) -> None:
    # JSON-quoted paths stay one line. Escaping '<' also prevents a path
    # from closing the HTML block in the Markdown step summary.
    summary = "\n".join(lines(report)).replace("&", "&amp;").replace("<", "&lt;")
    try:
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open(
            "a", encoding="utf-8"
        ) as stream:
            stream.write(
                "\n## Review controls changed\n\n<pre>\n" + summary + "\n</pre>\n"
            )
    except KeyError, OSError:
        print("::warning::controls_changed: could not write step summary")
    for category in report["categories"]:
        paths = [
            json.dumps(h["path"])
            for h in report["files"]
            if category in h["categories"]
        ]
        print("::warning::" + escape_annotation(category + ": " + ", ".join(paths)))
    if report["error"]:
        print("::warning::" + escape_annotation(lines(report)[0]))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="emit a JSON report")
    output.add_argument(
        "--github", action="store_true", help="write summary and warnings"
    )
    parser.add_argument("--git", default="git", help=argparse.SUPPRESS)
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args(argv)
    report: Report
    try:
        categories = cast(
            "list[Category]",
            json.loads(Path(__file__).with_name("categories.json").read_text("utf-8")),
        )
        report = detect(args.git, args.base, args.head, categories)
    except OSError, ValueError, subprocess.CalledProcessError:
        report = {
            "files": [],
            "categories": [],
            "error": "could not read Git range or control categories",
        }
    print(json.dumps(report, sort_keys=True) if args.json else "\n".join(lines(report)))
    if args.github:
        github_output(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
