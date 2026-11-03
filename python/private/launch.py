# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs one tool of the locked Python environment.

Usage: launch.py [--select] [--allow-empty] [--exclude PATTERN]...
    [--chdir DIR] -- TOOL [ARG]...

Started by the launcher script that python_tool generates, with the
interpreter and environment it sets up. TOOL is `python` (the interpreter
itself), `uv`, a console script of an installed package (run in this
process), or an executable in the environment's bin directory (a native
binary such as ruff or pyrefly).

--select appends the Python files under the current directory: `*.py` and
`*.pyi` files, and files whose first line is a python or `uv run` shebang.
Finding none is an error unless --allow-empty is given. --exclude takes
fnmatch patterns over the relative path. --chdir runs the tool from DIR,
relative to the current directory, and selects files there. `{env:NAME}` in an ARG
expands to the environment variable NAME.
"""

import fnmatch
import os
import re
import sys
from importlib.metadata import entry_points
from pathlib import Path

SHEBANG = re.compile(rb"^#!.*(\bpython[0-9.]*\b|\buv\b.*\brun\b)")


def is_python(path: Path) -> bool:
    """Tell whether path is a Python source file, by suffix or shebang."""
    if path.suffix in {".py", ".pyi"}:
        return True
    try:
        with path.open("rb") as source:
            first = source.readline()
    except OSError:
        return False
    return bool(SHEBANG.match(first))


def select(root: Path, excludes: list[str]) -> list[str]:
    """Return the Python files under root, relative and sorted."""
    found = []
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
    return re.sub(r"\{env:(\w+)\}", lambda m: os.environ.get(m.group(1), ""), arg)


def parse(argv: list[str]) -> tuple[dict[str, object], list[str]]:
    """Split the launcher options from the tool and its arguments."""
    options: dict[str, object] = {"select": False, "allow_empty": False, "exclude": [], "chdir": ""}
    while argv and argv[0] != "--":
        flag = argv.pop(0)
        if flag == "--select":
            options["select"] = True
        elif flag == "--allow-empty":
            options["allow_empty"] = True
        elif flag in {"--exclude", "--chdir"} and argv:
            value = argv.pop(0)
            if flag == "--exclude":
                options["exclude"].append(value)
            else:
                options["chdir"] = value
        else:
            raise SystemExit(f"launch.py: unexpected argument {flag!r}")
    if not argv[1:]:
        raise SystemExit("launch.py: no tool given")
    return options, argv[1:]


def main(argv: list[str]) -> int:
    """Run the tool; return its status if it runs in this process."""
    options, command = parse(argv)
    tool, args = command[0], [expand(arg) for arg in command[1:]]
    if options["chdir"]:
        os.chdir(options["chdir"])
    if options["select"]:
        files = select(Path.cwd(), options["exclude"])
        if not files and not options["allow_empty"]:
            print("launch.py: no Python files found, so nothing was checked", file=sys.stderr)
            return 1
        if not files:
            return 0
        print(f"launch.py: {len(files)} Python files", file=sys.stderr)
        args += files

    if tool == "python":
        os.execv(sys.executable, [sys.executable, *args])
    if tool == "uv":
        uv = os.environ["TBHB_PYTHON_UV"]
        os.execv(uv, [uv, *args])
    scripts = entry_points(group="console_scripts", name=tool)
    if scripts:
        sys.argv = [tool, *args]
        result = next(iter(scripts)).load()()
        return result if isinstance(result, int) else (0 if result is None else 1)
    binary = Path(os.environ["TBHB_PYTHON_BIN"]) / tool
    if not binary.is_file():
        raise SystemExit(f"launch.py: {tool!r} is neither a console script nor in the environment's bin")
    os.execv(binary, [str(binary), *args])
    return 1  # pragma: no cover


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
