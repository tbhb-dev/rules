# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
"""Fail unless mutmut killed every mutant.

Usage: uv run python tools/mutation_gate.py [STATS]

Without STATS the gate first runs `mutmut export-cicd-stats` (which `mutmut run`
does not do), then reads mutants/mutmut-cicd-stats.json. With STATS it only reads
that file. The gate exits 1 when any mutant survived, timed out, was suspicious, had no
tests or crashed with a segfault, when mutmut was interrupted, or when nothing
was mutated at all, and exits 0 otherwise. A short summary goes to stdout.
"""

import json
import subprocess  # nosec B404
import sys
from pathlib import Path

DEFAULT_STATS = Path("mutants/mutmut-cicd-stats.json")
# Any count above zero fails the gate.
MUST_BE_ZERO = ("survived", "timeout", "suspicious", "no_tests", "segfault")
REQUIRED = ("total", "killed", "skipped", *MUST_BE_ZERO)


def export_stats() -> None:
    """Write the stats file from the last `mutmut run`; exit if mutmut fails."""
    done = subprocess.run(  # nosec B603
        [sys.executable, "-m", "mutmut", "export-cicd-stats"],
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode != 0:
        message = f"mutmut export-cicd-stats failed: {done.stderr.strip()}"
        raise SystemExit(message)


def load_stats(path: Path) -> dict[str, object]:
    """Read the stats file, which must hold a JSON object with every key."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        message = f"cannot read {path}: {error}"
        raise SystemExit(message) from error
    if not isinstance(data, dict):
        message = f"{path} is not a JSON object"
        raise SystemExit(message)
    missing = [key for key in REQUIRED if key not in data]
    if missing:
        message = f"{path} lacks {', '.join(missing)}"
        raise SystemExit(message)
    return data


def problems(stats: dict[str, object]) -> list[str]:
    """Describe everything that stops the gate from passing."""
    found = [f"{stats[key]} {key}" for key in MUST_BE_ZERO if stats[key] != 0]
    if stats.get("check_was_interrupted_by_user"):
        found.append("run was interrupted")
    if stats["total"] == 0:
        found.append("no mutants were generated")
    # A failed stats pass leaves mutants "not checked", which none of the
    # counts above include, so a run that tested nothing would otherwise pass.
    counts = {key: int(str(stats[key])) for key in REQUIRED}
    accounted = counts["killed"] + counts["skipped"]
    accounted += sum(counts[key] for key in MUST_BE_ZERO)
    if counts["total"] > accounted:
        found.append(f"{counts['total'] - accounted} not checked")
    return found


def main(argv: list[str]) -> int:
    """Print a summary and return the exit status."""
    if len(argv) > 1:
        sys.stderr.write("usage: mutation_gate.py [STATS]\n")
        return 2
    if not argv:
        export_stats()
    stats = load_stats(Path(argv[0]) if argv else DEFAULT_STATS)
    found = problems(stats)
    print(
        f"mutants: {stats['total']} total, {stats['killed']} killed, "
        f"{stats['skipped']} skipped",
    )
    if found:
        print("FAIL: " + ", ".join(found))
        return 1
    print("ok: every mutant was killed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
