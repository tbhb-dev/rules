# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run import-linter and fail unless it checked something.

Usage: import_linter.py [LINT_IMPORTS_OPTION]...

Runs `lint-imports --no-cache` with the given options from the current
directory, where the contracts live in pyproject.toml's
`[tool.importlinter]` or in `.importlinter`. lint-imports passes when no
contract is defined and when it analysed no module, both of which prove
nothing, so this fails on either, after printing lint-imports' own output.
"""

import re
import subprocess  # nosec B404
import sys

ANALYZED = re.compile(r"^Analyzed (\d+) files", re.MULTILINE)
CONTRACTS = re.compile(r"^Contracts: (\d+) kept, (\d+) broken", re.MULTILINE)
COMMAND = "import sys; from importlinter.cli import lint_imports_command; sys.exit(lint_imports_command())"


def problems(output: str) -> list[str]:
    """Describe why a lint-imports run that passed proves nothing."""
    found = []
    analyzed = ANALYZED.search(output)
    if analyzed is None or int(analyzed.group(1)) == 0:
        found.append("no module was analysed")
    contracts = CONTRACTS.search(output)
    if contracts is None or int(contracts.group(1)) + int(contracts.group(2)) == 0:
        found.append("no contract is defined")
    return found


def main(argv: list[str]) -> int:
    """Run lint-imports and return its status, or 1 if it checked nothing."""
    done = subprocess.run(  # nosec B603
        [sys.executable, "-c", COMMAND, "--no-cache", *argv],
        capture_output=True,
        text=True,
        check=False,
    )
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        return done.returncode
    found = problems(done.stdout)
    if found:
        print(f"import_linter: FAIL: {', '.join(found)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
