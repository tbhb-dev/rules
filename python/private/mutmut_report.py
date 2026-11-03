# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run mutmut and write its outcome in tbhb_rules' mutation report format.

Usage: mutmut_report.py REPORT LOG

Runs from the directory mutmut should run in (the one whose pyproject.toml
holds `[tool.mutmut]`), inside the scratch copy the mutmut_report action
made. Runs `mutmut run`, `mutmut export-cicd-stats` and `mutmut results`,
and writes REPORT: one `key=value` per line with total, killed, skipped,
survived, timeout, suspicious, no_tests, segfault and interrupted, plus a
`mutant.<status>=<name>` line for each mutant not killed. A run that
produced no statistics is reported as interrupted, so the gate fails with
the log rather than the build. mutmut's own output goes to LOG.
"""

import json
import subprocess  # nosec B404
import sys
from pathlib import Path

COUNTS = (
    "total",
    "killed",
    "skipped",
    "survived",
    "timeout",
    "suspicious",
    "no_tests",
    "segfault",
)
# The statuses `mutmut results --all true` prints for mutants not killed.
NOT_KILLED = frozenset(
    {
        "survived",
        "timeout",
        "suspicious",
        "no tests",
        "segfault",
        "not checked",
        "skipped",
    },
)
STATS = Path("mutants/mutmut-cicd-stats.json")


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
    except OSError, ValueError:
        return None
    return data if isinstance(data, dict) else None


def report(stats: dict[str, object] | None, results: str) -> str:
    """Format the report from the cicd stats and `mutmut results` output."""
    if stats is None:
        lines = [f"{key}=0" for key in COUNTS] + ["interrupted=1"]
    else:
        lines = [f"{key}={int(str(stats.get(key, 0)))}" for key in COUNTS]
        interrupted = 1 if stats.get("check_was_interrupted_by_user") else 0
        lines.append(f"interrupted={interrupted}")
    for line in results.splitlines():
        name, _, status = line.strip().rpartition(": ")
        if name and status in NOT_KILLED:
            lines.append(f"mutant.{status.replace(' ', '_')}={name}")
    return "\n".join(lines) + "\n"


# Module-level, where mutmut leaves names alone: a mutated case still
# resolves on a case-insensitive filesystem.
PYPROJECT = "pyproject.toml"
HEADER = "[tool.mutmut]"
NO_GIT = "use_git_change_detection = false"
# Verdicts that depend on the machine (load, signals) rather than the code:
# the action fails on them, so Bazel never caches one.
UNSTABLE = ("timeout", "segfault", "suspicious", "interrupted")


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
    return [key for key in UNSTABLE if f"{key}=0" not in lines]


def main(argv: list[str]) -> int:
    """Run mutmut and write the report.

    Returns 2 on bad usage and 1 when the run timed out, crashed, was
    interrupted or found suspicious mutants, so that verdict is not cached.
    """
    if len(argv) != 2:  # noqa: PLR2004 - REPORT and LOG.
        print("usage: mutmut_report.py REPORT LOG", file=sys.stderr)
        return 2
    out, log = Path(argv[0]), Path(argv[1])
    log.write_text("")
    scratch_config(Path(PYPROJECT))
    mutmut(["run"], log)
    stats = None
    if mutmut(["export-cicd-stats"], log).returncode == 0:
        stats = load_stats(STATS)
    results = mutmut(["results", "--all", "true"], log).stdout
    text = report(stats, results)
    out.write_text(text)
    found = unstable(text)
    if found:
        print(f"mutmut_report: not cacheable: {', '.join(found)}", file=sys.stderr)
        sys.stderr.write(log.read_text())
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
