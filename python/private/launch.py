# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run one tool of the locked Python environment.

Usage: launch.py [--select] [--allow-empty] [--exclude PATTERN]...
    [--chdir DIR] -- TOOL [ARG]...

Started by the launcher script that python_tool generates, with the
interpreter and environment it sets up. TOOL is `python` (the interpreter
itself), `uv`, a console script of an installed package (run in this
process), or an executable in the environment's bin directory (a native
binary such as ruff or pyrefly).

--chdir runs the tool from DIR, relative to the current directory. --select
then appends the Python files under it: `*.py` and `*.pyi` files, and files
whose first line is a python or `uv run` shebang. Finding none is an error
unless --allow-empty is given, which makes the run a no-op instead.
--exclude takes fnmatch patterns over the relative path. `{env:NAME}` in an
ARG expands to the environment variable NAME.
"""

import fnmatch
import os
import re
import sys
from dataclasses import dataclass, field
from importlib.metadata import entry_points
from pathlib import Path
from typing import NoReturn

SHEBANG = re.compile(rb"^#!.*(\bpython[0-9.]*\b|\buv\b.*\brun\b)")
ENV_REFERENCE = re.compile(r"\{env:(\w+)\}")
PYTHON_SUFFIXES = frozenset({".py", ".pyi"})


class UsageError(Exception):
    """The launcher was called with arguments it does not accept."""


@dataclass
class Options:
    """The launcher's own options, before the `--`."""

    select: bool = False
    allow_empty: bool = False
    exclude: list[str] = field(default_factory=list[str])
    chdir: str = ""


def is_python(path: Path) -> bool:
    """Tell whether path is a Python source file, by suffix or shebang."""
    if path.suffix in PYTHON_SUFFIXES:
        return True
    with path.open("rb") as source:
        first = source.readline()
    return SHEBANG.match(first) is not None


def select(root: Path, excludes: list[str]) -> list[str]:
    """Return the Python files under root, relative and sorted."""
    found: list[str] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative.startswith(".git/") or not path.is_file():
            continue
        if any(fnmatch.fnmatch(relative, pattern) for pattern in excludes):
            continue
        if is_python(path):
            found.append(relative)
    return found


def expand(arg: str) -> str:
    """Replace each {env:NAME} in arg with that environment variable."""
    return ENV_REFERENCE.sub(lambda match: os.environ.get(match.group(1), ""), arg)


def parse(argv: list[str]) -> tuple[Options, list[str]]:
    """Split the launcher options from the tool and its arguments."""
    options = Options()
    rest = list(argv)
    while rest and rest[0] != "--":
        flag = rest.pop(0)
        if flag == "--select":
            options.select = True
        elif flag == "--allow-empty":
            options.allow_empty = True
        elif flag == "--exclude" and rest:
            options.exclude.append(rest.pop(0))
        elif flag == "--chdir" and rest:
            options.chdir = rest.pop(0)
        else:
            message = f"unexpected argument {flag!r}"
            raise UsageError(message)
    if len(rest) < 2:  # noqa: PLR2004 - the `--` and the tool.
        message = "no tool given"
        raise UsageError(message)
    return options, rest[1:]


def execute(argv: list[str]) -> NoReturn:
    """Replace this process with argv."""
    os.execv(argv[0], argv)  # noqa: S606


def run(tool: str, args: list[str]) -> int:
    """Run the tool with args; return its status if it runs in this process."""
    if tool == "python":
        execute([sys.executable, *args])
    if tool == "uv":
        execute([os.environ["TBHB_PYTHON_UV"], *args])
    for script in entry_points(group="console_scripts", name=tool):
        sys.argv = [tool, *args]
        result = script.load()()
        if result is None:
            return 0
        return result if isinstance(result, int) else 1
    binary = Path(os.environ["TBHB_PYTHON_BIN"]) / tool
    if not binary.is_file():
        message = f"{tool!r} is neither a console script nor in the environment's bin"
        raise UsageError(message)
    return execute([str(binary), *args])


def main(argv: list[str]) -> int:
    """Run the tool named in argv and return the exit status."""
    try:
        options, command = parse(argv)
    except UsageError as error:
        print(f"launch.py: {error}", file=sys.stderr)
        return 2
    tool, args = command[0], [expand(arg) for arg in command[1:]]
    if options.chdir:
        os.chdir(options.chdir)
    if options.select:
        files = select(Path.cwd(), options.exclude)
        if not files:
            if options.allow_empty:
                return 0
            print("launch.py: no Python files, so nothing was checked", file=sys.stderr)
            return 1
        print(f"launch.py: {len(files)} Python files", file=sys.stderr)
        args += files
    try:
        return run(tool, args)
    except UsageError as error:
        print(f"launch.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
