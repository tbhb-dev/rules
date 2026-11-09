# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run mutmut and write its outcome in tbhb_rules' mutation report format.

Usage: mutmut_report.py REPORT LOG [CHANGES PREFIX]

Runs from the directory mutmut should run in (the one whose pyproject.toml
holds `[tool.mutmut]`), inside the scratch copy the mutmut_report action
made, and writes REPORT in quality's shared format: one `key=value` per line
with total, killed, lived, not_covered, timeout, errored, skipped,
interrupted and scope, plus a `mutant.<status>=<name>` line, in mutmut's
own status names, for each mutant not killed. mutmut's output goes to LOG.

Without CHANGES the run is full (`scope=full`). CHANGES is the unit's slice
of quality's change set, and PREFIX the run directory relative to the tree
root. A slice that changes nothing in the unit runs nothing (`scope=diff`,
no mutants). A change the selection cannot scope by function makes the run
full; otherwise only the mutants of the changed functions run, and the
report counts only them (`selected` equals total) with `changed_units`, the
changed functions that have mutants. A mutant that mutmut ran outside the
selection, or left unrun inside it, is `mutant.unmapped=<name>`, which the
gate fails.
"""

import ast
import fnmatch
import json
import os
import subprocess  # nosec B404
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

# The shared report's outcome keys, and the mutmut statuses each one counts.
# A mutant the type checker rejects is invalid code, not a kill: like a
# mutant that doesn't compile, it counts as skipped (accounted, not gating)
# and stays listed with its own status.
OUTCOMES = {
    "killed": ("killed",),
    "lived": ("survived",),
    "not_covered": ("no tests",),
    "timeout": ("timeout",),
    "errored": ("suspicious", "segfault"),
    "skipped": ("skipped", "caught by type check"),
}
# The cicd stats keys behind each outcome.
STATS_KEYS = {
    "killed": ("killed",),
    "lived": ("survived",),
    "not_covered": ("no_tests",),
    "timeout": ("timeout",),
    "errored": ("suspicious", "segfault"),
    "skipped": ("skipped", "caught_by_type_check"),
}
NOT_RUN = "not checked"
STATS = Path("mutants/mutmut-cicd-stats.json")
# Module-level, where mutmut leaves names alone: a mutated case still
# resolves on a case-insensitive filesystem.
PYPROJECT = "pyproject.toml"
HEADER = "[tool.mutmut]"
NO_GIT = "use_git_change_detection = false"
# The container's CPU quota: cgroup v2's cpu.max ("<quota|max> <period>"),
# else cgroup v1's quota (-1 for none) and period files.
CPU_MAX = Path("/sys/fs/cgroup/cpu.max")
V1_QUOTA = Path("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
V1_PERIOD = Path("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
# Verdicts that depend on the machine (load, signals) rather than the code:
# the action fails on them, so Bazel never caches one.
UNSTABLE = ("timeout", "errored", "interrupted")
# A mutant mutmut never checked means the run stopped early (killed, out of
# memory, a crash), so it isn't cached either: a cached aborted run fails
# every later test with the same inputs.
NOT_CHECKED = "mutant." + NOT_RUN.replace(" ", "_") + "="

SEPARATOR = "ǁ"
TEST_NAMES = ("test_*.py", "*_test.py", "conftest.py")
SOURCE_PREFIXES = ("src.", "source.")
WHOLE_FILE = ("added", "deleted")

type Change = str | list[tuple[int, int]]


class ChangesError(ValueError):
    """The change set does not have the shared format."""


@dataclass
class Selection:
    """The outcome: full mode, or the functions (as mutant globs) to run."""

    full: bool = False
    reason: str = ""
    globs: list[str] = field(default_factory=list[str])


def table(value: object) -> dict[str, object]:
    """Return value as a JSON or TOML table, or an empty one otherwise."""
    return value if isinstance(value, dict) else {}


def array(value: object) -> list[object] | None:
    """Return value as a list, or None when it is not one."""
    return value if isinstance(value, list) else None


def load_changes(path: Path) -> dict[str, Change]:
    """Read a change set: each path's ranges, or "added" or "deleted"."""
    try:
        data = table(json.loads(path.read_text()))
    except json.JSONDecodeError as error:
        message = f"{path}: not JSON: {error.msg}"
        raise ChangesError(message) from error
    if data.get("version") != 1:
        message = f"{path}: not a version 1 change set"
        raise ChangesError(message)
    if not isinstance(data.get("files"), dict):
        message = f"{path}: `files` is not an object"
        raise ChangesError(message)
    changes: dict[str, Change] = {}
    for name, value in table(data.get("files")).items():
        if value in WHOLE_FILE:
            changes[name] = str(value)
            continue
        ranges = array(value)
        if ranges is None:
            message = f"{path}: {name}: neither ranges nor added or deleted"
            raise ChangesError(message)
        changes[name] = [line_range(path, name, item) for item in ranges]
    return changes


def line_range(path: Path, name: str, value: object) -> tuple[int, int]:
    """Return one [start, end] range of a change set as a tuple."""
    pair = array(value) or []
    ints = [
        item for item in pair if isinstance(item, int) and not isinstance(item, bool)
    ]
    if len(pair) == 2 and len(ints) == 2 and 1 <= ints[0] <= ints[1]:  # noqa: PLR2004
        return ints[0], ints[1]
    message = f"{path}: {name}: bad range {value!r}"
    raise ChangesError(message)


def is_test(rel: PurePosixPath, do_not_mutate: list[str]) -> bool:
    """Tell whether a unit-relative path is a test (or test support) file."""
    if any(fnmatch.fnmatch(rel.name, pattern) for pattern in TEST_NAMES):
        return True
    return any(fnmatch.fnmatch(str(rel), pattern) for pattern in do_not_mutate)


def functions(source: str) -> list[tuple[str, int, int]]:
    """Return mutmut's mangled name and line span of each function.

    mutmut mutates top-level functions and the methods of top-level classes;
    a nested function belongs to its enclosing one. A span starts at the
    first decorator.
    """
    found = []
    for node in ast.parse(source).body:
        if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
            found.append((f"x_{node.name}", _start(node), _end(node)))
        elif isinstance(node, ast.ClassDef):
            found.extend(
                (
                    f"x{SEPARATOR}{node.name}{SEPARATOR}{item.name}",
                    _start(item),
                    _end(item),
                )
                for item in node.body
                if isinstance(item, ast.FunctionDef | ast.AsyncFunctionDef)
            )
    return found


def _start(node: ast.FunctionDef | ast.AsyncFunctionDef) -> int:
    return min([node.lineno, *(d.lineno for d in node.decorator_list)])


def _end(node: ast.FunctionDef | ast.AsyncFunctionDef) -> int:
    return node.end_lineno or node.lineno


def module_name(rel: PurePosixPath) -> str:
    """Return the module mutmut names a unit-relative source file."""
    name = ".".join(rel.with_suffix("").parts)
    for prefix in SOURCE_PREFIXES:
        name = name.removeprefix(prefix)
    return name.removesuffix(".__init__")


def under(rel: PurePosixPath, source_paths: list[str]) -> bool:
    """Tell whether rel is under one of mutmut's source paths."""
    return any(rel.is_relative_to(PurePosixPath(path)) for path in source_paths)


def select(
    changes: dict[str, Change],
    prefix: str,
    root: Path,
    source_paths: list[str],
    do_not_mutate: list[str],
) -> Selection:
    """Choose the mutants of the unit at root (prefix in the repository).

    Every path in the slice is an input of the unit. One outside the run
    directory (a dependency's source, the root config) can change any
    verdict, so it makes the run full, as do the changes the line filter
    cannot reason about: an added or deleted file, a test file, a file that
    is not Python source under the mutated paths, and code outside every
    function.
    """
    selection = Selection()
    base = PurePosixPath(prefix)
    for name, change in sorted(changes.items()):
        path = PurePosixPath(name)
        if not path.is_relative_to(base):
            return Selection(full=True, reason=f"{path}, outside the unit, changed")
        rel = path.relative_to(base)
        reason = _full_reason(rel, change, source_paths, do_not_mutate)
        # A change with no text hunks (mode only) changes no function.
        if reason is None and isinstance(change, list) and change:
            reason = _add(selection, rel, (root / rel).read_text(), change)
        if reason:
            return Selection(full=True, reason=reason)
    selection.globs = sorted(set(selection.globs))
    return selection


def _full_reason(
    rel: PurePosixPath,
    change: Change,
    source_paths: list[str],
    do_not_mutate: list[str],
) -> str | None:
    if isinstance(change, str):
        return f"{rel} was {change}"
    if is_test(rel, do_not_mutate):
        return f"{rel} is a test file"
    if rel.suffix != ".py" or not under(rel, source_paths):
        return f"{rel} is not Python source under the mutated paths"
    return None


def _add(
    selection: Selection,
    rel: PurePosixPath,
    source: str,
    ranges: list[tuple[int, int]],
) -> str | None:
    spans = functions(source)
    module = module_name(rel)
    for start, end in ranges:
        hit = [name for name, first, last in spans if start <= last and first <= end]
        if not hit:
            return f"{rel}:{start}-{end} changes code outside any function"
        selection.globs.extend(f"{module}.{name}__mutmut_*" for name in hit)
    return None


def read_text(path: Path) -> str:
    """Return a cgroup file's text without its newline, or "" when unreadable.

    The files can be unreadable inside a Bazel sandbox.
    """
    try:
        return path.read_text().strip()
    # Python before 3.14 requires the parentheses that ruff's 3.15 target strips.
    except (OSError, ValueError):  # fmt: skip
        return ""


def max_children() -> list[str]:
    """Return mutmut's `--max-children` for a CPU quota below the host's CPUs.

    mutmut sizes its workers from os.cpu_count(), which a container's cgroup
    CPU quota can be far below. The count is the quota over its period,
    rounded up, at least 1. Nothing is returned when no quota is set, the
    files don't hold integers, or the count is not below the CPU count.
    cpu_quota.sh in setup-bazel-ci implements the same rule: keep the two in
    step.
    """
    # partition and rpartition agree on the file's single space.
    quota, _, period = read_text(CPU_MAX).partition(" ")  # pragma: no mutate
    if not quota:
        quota, period = read_text(V1_QUOTA), read_text(V1_PERIOD)
    if not all(field.isascii() and field.isdecimal() for field in (quota, period)):
        return []  # "max" and -1 end here too.
    if int(period) == 0:
        return []
    workers = max(1, -(-int(quota) // int(period)))
    cpus = os.cpu_count()
    if cpus is not None and workers >= cpus:
        return []
    return ["--max-children", str(workers)]


def mutmut(args: list[str], log: Path) -> subprocess.CompletedProcess[str]:
    """Run one mutmut command, appending its output to log."""
    done = subprocess.run(  # nosec B603
        [sys.executable, "-m", "mutmut", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    with log.open("a") as out:
        out.write(f"$ mutmut {' '.join(args)} (exit {done.returncode})\n")
        out.write(f"{done.stdout}{done.stderr}\n")
    return done


def load_stats(path: Path) -> dict[str, object] | None:
    """Read the cicd stats, or None when there are none to read."""
    try:
        data = json.loads(path.read_text())
    # This file runs in the consumer's interpreter, and Python before 3.14
    # requires the parentheses that ruff's 3.15 target strips.
    except (OSError, ValueError):  # fmt: skip
        return None
    return data if isinstance(data, dict) else None


def results_by_name(results: str) -> dict[str, str]:
    """Map each mutant `mutmut results --all true` lists to its status."""
    found = {}
    for line in results.splitlines():
        name, _, status = line.strip().rpartition(": ")
        if name:
            found[name] = status
    return found


def mutant_lines(statuses: dict[str, str]) -> list[str]:
    """Return a `mutant.<status>=<name>` line for each mutant not killed."""
    return [
        f"mutant.{status.replace(' ', '_')}={name}"
        for name, status in statuses.items()
        if status not in OUTCOMES["killed"]
    ]


def report(stats: dict[str, object] | None, results: str) -> str:
    """Format a full run's report from the cicd stats and `mutmut results`."""
    if stats is None:
        lines = ["total=0", *(f"{key}=0" for key in OUTCOMES), "interrupted=1"]
    else:
        lines = [f"total={int(str(stats.get('total', 0)))}"]
        lines += [
            f"{key}={sum(int(str(stats.get(name, 0))) for name in names)}"
            for key, names in STATS_KEYS.items()
        ]
        interrupted = 1 if stats.get("check_was_interrupted_by_user") else 0
        lines.append(f"interrupted={interrupted}")
    lines.append("scope=full")
    lines += mutant_lines(results_by_name(results))
    return "\n".join(lines) + "\n"


def diff_report(results: str, selection: Selection) -> str:
    """Format a diff run's report: only the selected mutants count.

    A selected mutant mutmut did not run, and one it ran that was not
    selected, are both unmapped: the selection and the tool disagree.
    """
    statuses = results_by_name(results)
    selected = {
        name: status
        for name, status in statuses.items()
        if any(fnmatch.fnmatch(name, glob) for glob in selection.globs)
    }
    values = list(selected.values())
    lines = [f"total={len(selected)}"]
    lines += [
        f"{key}={sum(values.count(status) for status in names)}"
        for key, names in OUTCOMES.items()
    ]
    units = [
        glob
        for glob in selection.globs
        if any(fnmatch.fnmatch(name, glob) for name in selected)
    ]
    lines += ["interrupted=0", "scope=diff", f"selected={len(selected)}"]
    lines.append(f"changed_units={len(units)}")
    lines += mutant_lines({k: v for k, v in selected.items() if v != NOT_RUN})
    lines += [
        f"mutant.unmapped={name}"
        for name, status in statuses.items()
        if (name in selected) == (status == NOT_RUN)
    ]
    return "\n".join(lines) + "\n"


def scratch_config(path: Path) -> None:
    """Turn off mutmut's git change detection in the copy's pyproject.toml.

    The copy has no history, and a report must follow from its inputs alone.
    """
    if not path.is_file():
        return
    text = path.read_text()
    if "use_git_change_detection" in text:
        return
    lines = text.splitlines(keepends=True)
    for number, line in enumerate(lines):
        if line.strip() == HEADER:
            lines.insert(number + 1, NO_GIT + "\n")
            path.write_text("".join(lines))
            return


def unstable(text: str) -> list[str]:
    """Return the machine-dependent verdicts a report records."""
    lines = text.splitlines()
    found = [key for key in UNSTABLE if f"{key}=0" not in lines]
    if any(line.startswith(NOT_CHECKED) for line in lines):
        found.append("not_checked")
    return found


def mutmut_paths(path: Path) -> tuple[list[str], list[str]]:
    """Return [tool.mutmut]'s source_paths and do_not_mutate from pyproject."""
    with path.open("rb") as source:
        config = table(table(tomllib.load(source).get("tool")).get("mutmut"))
    source_paths = array(config.get("source_paths")) or []
    do_not_mutate = array(config.get("do_not_mutate")) or []
    return [str(p) for p in source_paths], [str(p) for p in do_not_mutate]


def choose(changes: Path, prefix: str) -> Selection:
    """Choose the run's mutants from the unit's slice of the change set."""
    loaded = load_changes(changes)
    if not loaded:
        return Selection()
    source_paths, do_not_mutate = mutmut_paths(Path(PYPROJECT))
    if not source_paths:
        return Selection(full=True, reason="[tool.mutmut] sets no source_paths")
    return select(loaded, prefix, Path(), source_paths, do_not_mutate)


def run_full(log: Path) -> str:
    """Run every mutant and return the report."""
    mutmut(["run", *max_children()], log)
    stats = None
    if mutmut(["export-cicd-stats"], log).returncode == 0:
        stats = load_stats(STATS)
    results = mutmut(["results", "--all", "true"], log).stdout
    return report(stats, results)


def run_diff(log: Path, selection: Selection) -> str:
    """Run the selected mutants and return the diff report."""
    if not selection.globs:
        # Any text without a "name: status" line reads as no results.
        return diff_report("", selection)  # pragma: no mutate
    mutmut(["run", *max_children(), *selection.globs], log)
    return diff_report(mutmut(["results", "--all", "true"], log).stdout, selection)


def main(argv: list[str]) -> int:
    """Run mutmut and write the report.

    Returns 2 on bad usage and 1 when the run timed out, errored or was
    interrupted, so that verdict is not cached.
    """
    if len(argv) not in {2, 4}:
        print("usage: mutmut_report.py REPORT LOG [CHANGES PREFIX]", file=sys.stderr)
        return 2
    out, log = Path(argv[0]), Path(argv[1])
    log.write_text("")
    scratch_config(Path(PYPROJECT))
    selection = Selection(full=True, reason="no change set")
    if len(argv) == 4:  # noqa: PLR2004 - REPORT, LOG, CHANGES and PREFIX.
        try:
            selection = choose(Path(argv[2]), argv[3])
        except ChangesError as error:
            print(f"mutmut_report: {error}", file=sys.stderr)
            return 2
    mode = f"full: {selection.reason}" if selection.full else "diff"
    with log.open("a") as out_log:
        out_log.write(f"mutmut_report: {mode}\n")
    text = run_full(log) if selection.full else run_diff(log, selection)
    out.write_text(text)
    found = unstable(text)
    if found:
        print(f"mutmut_report: not cacheable: {', '.join(found)}", file=sys.stderr)
        sys.stderr.write(log.read_text())
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
