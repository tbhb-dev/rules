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

COUNTS = ("total", "killed", "skipped", "survived", "timeout", "suspicious", "no_tests", "segfault")
STATUSES = {
    "survived",
    "timeout",
    "suspicious",
    "no tests",
    "segfault",
    "not checked",
    "skipped",
}


def mutmut(args: list[str], log: Path) -> subprocess.CompletedProcess[str]:
    """Run one mutmut command, appending its output to log."""
    done = subprocess.run(  # nosec B603
        [sys.executable, "-m", "mutmut", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    with log.open("a") as out:
        out.write(f"$ mutmut {' '.join(args)} (exit {done.returncode})\n{done.stdout}{done.stderr}\n")
    return done


def report(stats: dict[str, object] | None, results: str) -> str:
    """Format the report from the cicd stats and `mutmut results` output."""
    if stats is None:
        lines = [f"{key}=0" for key in COUNTS] + ["interrupted=1"]
    else:
        lines = [f"{key}={int(str(stats.get(key, 0)))}" for key in COUNTS]
        lines.append(f"interrupted={1 if stats.get('check_was_interrupted_by_user') else 0}")
    for line in results.splitlines():
        name, _, status = line.strip().rpartition(": ")
        if name and status in STATUSES:
            lines.append(f"mutant.{status.replace(' ', '_')}={name}")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    """Run mutmut and write the report; fail only on bad usage."""
    if len(argv) != 2:  # noqa: PLR2004
        sys.stderr.write("usage: mutmut_report.py REPORT LOG\n")
        return 2
    out, log = Path(argv[0]), Path(argv[1])
    log.write_text("")
    mutmut(["run"], log)
    stats = None
    if mutmut(["export-cicd-stats"], log).returncode == 0:
        try:
            stats = json.loads(Path("mutants/mutmut-cicd-stats.json").read_text())
        except (OSError, ValueError):
            stats = None
    results = mutmut(["results", "--all", "true"], log).stdout
    out.write_text(report(stats, results))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
