# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run one tool of the locked Python environment.

Usage: launch.py [--select] [--filter] [--allow-empty] [--exclude PATTERN]...
    [--chdir DIR] [--member DIR]... -- TOOL [ARG]...

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

--member names an editable workspace member's directory, relative to the
current directory. Before anything else, each member is installed from
the tree the launcher runs in, as `uv sync` installs an editable member:
its metadata (so `importlib.metadata` finds it) and its console scripts
(on PATH, as .exe launchers on Windows), into a scratch prefix. The code
itself is imported from the member's source root on PYTHONPATH, so it is
the copy's code, mutated or not. Subprocesses inherit the install.
"""

import base64
import fnmatch
import hashlib
import os
import re
import subprocess  # nosec B404
import sys
import sysconfig
import tempfile
import tomllib
import zipfile
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
    filter: bool = False
    allow_empty: bool = False
    exclude: list[str] = field(default_factory=list[str])
    chdir: str = ""
    members: list[str] = field(default_factory=list[str])


# Module-level, where mutmut leaves names alone: a mutated case still
# resolves on a case-insensitive filesystem.
PYPROJECT = "pyproject.toml"
WINDOWS = os.name == "nt"
# The entry-point groups a [project] table declares as tables of its own.
SCRIPT_GROUPS = (("scripts", "console_scripts"), ("gui-scripts", "gui_scripts"))
WHEEL = (
    "Wheel-Version: 1.0\nGenerator: tbhb_rules\nRoot-Is-Purelib: true\n"
    "Tag: py3-none-any\n"
)


def normalize(name: str) -> str:
    """Return a distribution name as wheel file names spell it."""
    return re.sub(r"[-_.]+", "_", name).lower()


def table(value: object) -> dict[str, object]:
    """Return value as a TOML table, or an empty one if it is not a table."""
    return value if isinstance(value, dict) else {}


def entry_points_text(project: dict[str, object]) -> str:
    """Return entry_points.txt for a [project] table."""
    groups = {group: table(project.get(key)) for key, group in SCRIPT_GROUPS}
    for group, entries in table(project.get("entry-points")).items():
        groups[group] = table(entries)
    sections = [
        "\n".join(
            [f"[{group}]", *(f"{name} = {target}" for name, target in entries.items())]
        )
        for group, entries in groups.items()
        if entries
    ]
    return "".join(f"{section}\n" for section in sections)


def record_line(name: str, data: bytes) -> str:
    """Return the RECORD line of one wheel file."""
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).replace(b"=", b"")
    return f"{name},sha256={digest.decode()},{len(data)}"


def member_wheel(member: Path, out: Path) -> Path:
    """Write a metadata-only wheel for the member and return its path.

    The wheel carries the member's name, version and entry points from its
    pyproject.toml and no code: the code comes from the source root on
    PYTHONPATH. A dynamic or missing version is "0".
    """
    with (member / PYPROJECT).open("rb") as source:
        project = table(tomllib.load(source).get("project"))
    name = str(project["name"])
    version = str(project.get("version", "0"))
    info = f"{normalize(name)}-{version}.dist-info"
    files = {
        f"{info}/METADATA": (
            f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n"
        ),
        f"{info}/WHEEL": WHEEL,
        f"{info}/entry_points.txt": entry_points_text(project),
    }
    wheel = out / f"{normalize(name)}-{version}-py3-none-any.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        record = []
        for path, text in files.items():
            archive.writestr(path, text)
            record.append(record_line(path, text.encode()))
        record.append(f"{info}/RECORD,,")
        archive.writestr(f"{info}/RECORD", "\n".join(record) + "\n")
    return wheel


def install_members(members: list[str]) -> tuple[str, str]:
    """Install the members' metadata and scripts; return (site dir, scripts dir).

    uv installs the wheels offline, without dependencies, into a scratch
    prefix, and writes the console scripts for this platform. A member the
    tree does not hold (a unit's copy has only the members it depends on)
    is left out: nothing in the tree can import it.
    """
    prefix = Path(
        tempfile.mkdtemp(prefix="members-", dir=os.environ.get("TEST_TMPDIR"))
    )
    present = [Path(m) for m in members if (Path(m) / PYPROJECT).is_file()]
    wheels = [str(member_wheel(member, prefix)) for member in present]
    command = [os.environ["TBHB_PYTHON_UV"], "pip", "install", "--quiet", "--offline"]
    command += ["--no-deps", "--python", sys.executable, "--prefix", str(prefix)]
    env = os.environ | {"UV_CACHE_DIR": str(prefix / "cache"), "UV_NO_CONFIG": "1"}
    if wheels:
        done = subprocess.run([*command, *wheels], env=env, check=False)  # nosec B603
        if done.returncode != 0:
            message = f"installing the workspace members failed ({done.returncode})"
            raise UsageError(message)
    paths = {"base": str(prefix)}
    return sysconfig.get_path("purelib", vars=paths), sysconfig.get_path(
        "scripts", vars=paths
    )


def use_members(members: list[str]) -> None:
    """Install the members and put them on sys.path, PYTHONPATH and PATH."""
    site, scripts = install_members(members)
    sys.path.append(site)
    pythonpath = [os.environ.get("PYTHONPATH"), site]
    os.environ["PYTHONPATH"] = os.pathsep.join(filter(None, pythonpath))
    os.environ["PATH"] = os.pathsep.join(
        filter(None, [scripts, os.environ.get("PATH")])
    )


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
    return ENV_REFERENCE.sub(lambda match: os.environ.get(match.group(1)) or "", arg)


def parse(argv: list[str]) -> tuple[Options, list[str]]:
    """Split the launcher options from the tool and its arguments."""
    options = Options()
    rest = list(argv)
    while rest and rest[0] != "--":
        flag = rest.pop(0)
        if flag == "--select":
            options.select = True
        elif flag == "--filter":
            options.filter = True
        elif flag == "--allow-empty":
            options.allow_empty = True
        elif flag == "--exclude" and rest:
            options.exclude.append(rest.pop(0))
        elif flag == "--chdir" and rest:
            options.chdir = rest.pop(0)
        elif flag == "--member" and rest:
            options.members.append(rest.pop(0))
        else:
            message = f"unexpected argument {flag!r}"
            raise UsageError(message)
    if len(rest) < 2:  # noqa: PLR2004 - the `--` and the tool.
        message = "no tool given"
        raise UsageError(message)
    return options, rest[1:]


def execute(argv: list[str]) -> NoReturn:
    """Replace this process with argv.

    Windows has no exec: os.execv there starts the program and ends this
    process at once with status 0, so the launcher waits and passes the
    status on instead.
    """
    if WINDOWS:
        sys.exit(subprocess.run(argv, check=False).returncode)  # nosec B603
    # The launcher exists to become the tool, so it execs without a shell.
    os.execv(argv[0], argv)  # noqa: S606 # nosec B606


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
    if WINDOWS and not binary.is_file():
        binary = binary.with_name(tool + ".exe")
    if not binary.is_file():
        message = f"{tool!r} is neither a console script nor in the environment's bin"
        raise UsageError(message)
    return execute([str(binary), *args])


def gather(options: Options, args: list[str]) -> list[str] | None:
    """Apply `filter` and `select` to args; None when no Python file is left."""
    if options.filter:
        args = [arg for arg in args if not Path(arg).is_file() or is_python(Path(arg))]
        if not any(Path(arg).is_file() for arg in args):
            return None
    if options.select:
        files = select(Path.cwd(), options.exclude)
        if not files:
            return None
        print(f"launch.py: {len(files)} Python files", file=sys.stderr)
        args = [*args, *files]
    return args


def main(argv: list[str]) -> int:
    """Run the tool named in argv and return the exit status."""
    try:
        options, command = parse(argv)
        tool, args = command[0], [expand(arg) for arg in command[1:]]
        if options.members:
            use_members(options.members)
        if options.chdir:
            os.chdir(options.chdir)
        found = gather(options, args)
        if found is None:
            if options.allow_empty:
                return 0
            print("launch.py: no Python files, so nothing was checked", file=sys.stderr)
            return 1
        return run(tool, found)
    except UsageError as error:
        print(f"launch.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
