# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
"""Checks a commit message's subject line.

Reads a message on stdin (or the file named by the first argument) and prints
one problem per line. Exits 1 when there is at least one. Every commit on a
pull request branch lands on main, so the subject has to read well on its own.
"""

import re
import sys
from pathlib import Path

MAX_LENGTH = 72
TYPES = "build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test"
CONVENTIONAL = re.compile(rf"^(?:{TYPES})(?:\([^()\s][^()]*\))?!?: (?P<summary>\S.*)$")
REWRITE_PREFIXES = ("fixup!", "squash!", "amend!")
WIP = re.compile(r"(?<![a-z0-9])wip(?![a-z0-9])", re.IGNORECASE)
# `git revert` writes `Revert "<original subject>"`, and reverting a revert
# writes `Reapply "<original subject>"`. Both stay as written.
REVERT = re.compile(r'^(?:Revert|Reapply) ".+"$')
# Renovate's dependency subjects (`update` and `pin`) name the package, so they
# can run long.
DEPENDENCY_UPDATE = re.compile(r"^(?:chore|fix)\(deps(?:-dev)?\): (?:update|pin) ")
GENERIC = frozenset(
    {
        "address feedback",
        "address review",
        "address review comments",
        "change",
        "changes",
        "fix",
        "fixes",
        "misc",
        "review feedback",
        "tweak",
        "tweaks",
        "update",
        "updates",
        "wip",
    }
)


def _normalize(text: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9 ]", " ", text.lower()).split())


def problems(subject: str) -> list[str]:
    """Return what is wrong with `subject`, empty when it is acceptable."""
    if REVERT.match(subject):
        return []
    found = []
    if subject.startswith(REWRITE_PREFIXES):
        found.append("fixup!, squash! and amend! subjects must be reworded")
    if WIP.search(subject):
        found.append("WIP subjects are not allowed")
    if len(subject) > MAX_LENGTH and not DEPENDENCY_UPDATE.match(subject):
        found.append(f"subject is {len(subject)} characters; the limit is {MAX_LENGTH}")
    match = CONVENTIONAL.match(subject)
    if match is None:
        found.append("subject must have the form type(scope): summary")
    if _normalize(subject) in GENERIC or (
        match is not None and _normalize(match.group("summary")) in GENERIC
    ):
        found.append("subject is too generic; say what changed")
    return found


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        text = Path(argv[1]).read_text(encoding="utf-8")
    else:
        text = sys.stdin.read()
    subject = text.split("\n", 1)[0].rstrip("\r")
    found = problems(subject)
    for problem in found:
        print(problem)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
