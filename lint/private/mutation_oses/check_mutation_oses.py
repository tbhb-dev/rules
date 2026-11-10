# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Check explicit mutation OS lists against platform signals in source trees."""

import argparse
import ast
import itertools
import re
import sys
from pathlib import Path

ALL = frozenset({"linux", "macos", "windows"})
UNIX = ALL - {"windows"}
# Language, location, expression, implied OSes. This is the signal table.
PATTERNS = (
    ("go", "tag", "linux", frozenset({"linux"})),
    ("go", "tag", "darwin", frozenset({"macos"})),
    ("go", "tag", "windows", frozenset({"windows"})),
    ("go", "tag", "unix", UNIX),
    ("go", "name", r"_linux(?:_[a-z0-9]+)?(?:_test)?\.go$", frozenset({"linux"})),
    ("go", "name", r"_darwin(?:_[a-z0-9]+)?(?:_test)?\.go$", frozenset({"macos"})),
    ("go", "name", r"_windows(?:_[a-z0-9]+)?(?:_test)?\.go$", frozenset({"windows"})),
    ("go", "name", r"_unix(?:_[a-z0-9]+)?(?:_test)?\.go$", UNIX),
    ("go", "code", r"\bruntime\s*\.\s*GOOS\b", ALL),
    ("go", "code", r"\b(?:filepath\s*\.\s*Separator|os\s*\.\s*PathSeparator)\b", ALL),
    (
        "go",
        "code",
        r"\bos\s*\.\s*(?:Chmod|FileMode)\b|\bMode\s*\(\s*\)\s*\.\s*Perm\b",
        ALL,
    ),
    ("go", "code", r'"os/exec"', ALL),
    ("go", "code", r'\bsyscall\s*\.|"os/signal"', ALL),
    ("py", "code", r"\bsys\s*\.\s*platform\b", ALL),
    ("py", "code", r"\bos\s*\.\s*name\b", ALL),
    ("py", "code", r"\bplatform\s*\.\s*system\s*\(", ALL),
    ("py", "code", r"\bos\s*\.\s*chmod\b", ALL),
    ("py", "code", r"\bsubprocess\b", ALL),
    ("py", "code", r"\bsignal\b", ALL),
    ("py", "code", r"\b(?:os\s*\.\s*path|posixpath|ntpath)\b", ALL),
    ("py", "code", r"\b(?:PureWindowsPath|WindowsPath)\b", frozenset({"windows"})),
)
TAGS = {
    expression: oses for _, location, expression, oses in PATTERNS if location == "tag"
}
BUILD_TAG = re.compile(r"^//\s*(go:build|\+build)\s+(.+)$", re.MULTILINE)
MACROS = {"gomutants_test": "go", "mutmut_test": "py"}


def possibilities(node: ast.expr, os: str) -> set[bool]:
    """Evaluate OS tags; other build tags may independently be true or false."""
    match node:
        case ast.Name(id=tag):
            return {os in TAGS[tag]} if tag in TAGS else {False, True}
        case ast.UnaryOp(op=ast.Not(), operand=operand):
            return {not value for value in possibilities(operand, os)}
        case ast.BoolOp(op=op, values=values):
            combine = all if isinstance(op, ast.And) else any
            return {
                combine(values)
                for values in itertools.product(*(possibilities(v, os) for v in values))
            }
        case _:
            msg = "unsupported Go build constraint"
            raise ValueError(msg)


def build_oses(text: str) -> frozenset[str]:
    """Intersect Go build expressions, preferring go:build over legacy lines."""
    tags = BUILD_TAG.findall(text)
    modern = [expression for kind, expression in tags if kind == "go:build"]
    expressions = modern or [
        " || ".join(" && ".join(term.split(",")) for term in expression.split())
        for _, expression in tags
    ]
    allowed = ALL
    for expression in expressions:
        translated = expression.replace("&&", " and ").replace("||", " or ")
        tree = ast.parse(translated.replace("!", " not ").strip(), mode="eval")
        allowed = allowed & {os for os in ALL if True in possibilities(tree.body, os)}
    return allowed


def implied_oses(path: Path) -> frozenset[str]:
    """Union lexical signals, narrowed by Go filename and build constraints."""
    language = path.suffix[1:]
    text = path.read_bytes().decode()
    found: frozenset[str] = frozenset()
    allowed = build_oses(text) if language == "go" else ALL
    for lang, location, expression, oses in PATTERNS:
        if lang != language or location == "tag":
            continue
        subject = path.name if location == "name" else text
        if re.search(expression, subject):
            found = found | oses
            if location == "name":
                allowed = allowed & oses
    # An OS-naming build tag is itself a signal, even without another hit.
    if (
        language == "go"
        and BUILD_TAG.search(text)
        and any(
            re.search(r"\b" + tag + r"\b", expression)
            for _, expression in BUILD_TAG.findall(text)
            for tag in TAGS
        )
    ):
        found = found | allowed
    return found & allowed


def restriction(node: ast.expr, assignments: dict[str, ast.expr]) -> list[str] | None:
    """Read literal attributes, including a top-level constant reference."""
    if isinstance(node, ast.Name):
        node = assignments[node.id]
    value: object = ast.literal_eval(node)
    if value is None:
        return None
    if not isinstance(value, list):
        raise TypeError
    values: list[object] = value
    names: list[str] = []
    for name in values:
        if not isinstance(name, str) or name not in ALL:
            raise ValueError
        names.append(name)
    return names


def source_directories(call: ast.Call, package: Path, root: Path) -> set[Path]:
    """Include the macro package and directories of literal local source labels."""
    directories = {package}
    for keyword in call.keywords:
        if keyword.arg not in {"srcs", "tests"}:
            continue
        for value in ast.walk(keyword.value):
            if not isinstance(value, ast.Constant):
                continue
            label = value.value
            if isinstance(label, str) and label.startswith("//"):
                directories.add(root / label[2:].split(":")[0])
    return directories


def check_call(
    call: ast.Call, language: str, build: Path, root: Path, sources: list[Path]
) -> list[str]:
    """Check one mutation declaration against the supplied source files."""
    attributes = {keyword.arg: keyword.value for keyword in call.keywords}
    if "mutation_oses" not in attributes:
        return []
    location = f"{build.relative_to(root).as_posix()}:{call.lineno}"
    tree = ast.parse(build.read_bytes())
    assignments = {
        node.targets[0].id: node.value
        for node in tree.body
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
    }
    try:
        oses = restriction(attributes["mutation_oses"], assignments)
        if oses is None:
            return []
    except KeyError, TypeError, ValueError:
        return [
            (
                f"{location}: mutation_oses must be a literal list of "
                "linux, macos, windows or None"
            )
        ]
    directories = source_directories(call, build.parent, root)
    required: frozenset[str] = frozenset()
    for path in sources:
        if path.suffix == "." + language and any(
            path.is_relative_to(directory) for directory in directories
        ):
            required = required | implied_oses(path)
    missing = sorted(required - set(oses))
    if missing:
        return [f"{location}: mutation_oses missing {', '.join(missing)}"]
    return []


def check_build(build: Path, root: Path, sources: list[Path]) -> list[str]:
    """Check direct calls with explicit restrictions; unset and None pass."""
    tree = ast.parse(build.read_bytes())
    errors: list[str] = []
    for call in ast.walk(tree):
        if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name):
            continue
        if call.func.id in MACROS:
            errors.extend(check_call(call, MACROS[call.func.id], build, root, sources))
    return errors


def check(root: Path) -> list[str]:
    """Check supplied BUILD files and source files; fixture trees are excluded."""
    files = sorted(
        path
        for path in root.rglob("*")
        if "testdata" not in path.relative_to(root).parts and path.is_file()
    )
    sources = [path for path in files if path.suffix in {".go", ".py"}]
    errors: list[str] = []
    for build in files:
        if build.name in {"BUILD", "BUILD.bazel"}:
            errors.extend(check_build(build, root, sources))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check mutation OS lists against source code."
    )
    parser.add_argument("root", nargs="?", type=Path, default=Path())
    args = parser.parse_args(argv)
    errors = check(args.root)
    for error in errors:
        sys.stdout.write(error + "\n")
    if errors:
        return 1
    sys.stdout.write("OK: mutation OS lists cover platform-specific code\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
