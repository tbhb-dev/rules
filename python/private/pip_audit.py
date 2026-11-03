# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Audit the locked dependencies of a uv project with pip-audit.

Usage: pip_audit.py [PIP_AUDIT_OPTION]...

Runs from BUILD_WORKSPACE_DIRECTORY under `bazel run`, else from the current
directory (a test's copy of the tree). Exports every package uv.lock pins,
for all members and groups but not the members themselves, as a pylock.toml,
and audits that with `pip-audit --locked`.
"""

import os
import subprocess  # nosec B404
import sys
import tempfile
from pathlib import Path


def main(argv: list[str]) -> int:
    """Export the lock and audit it; return pip-audit's status."""
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if workspace:
        os.chdir(workspace)
    with tempfile.TemporaryDirectory() as work:
        lock = Path(work) / "pylock.toml"
        subprocess.run(  # nosec B603
            [
                os.environ["TBHB_PYTHON_UV"],
                "export",
                "--quiet",
                "--frozen",
                "--all-packages",
                "--all-groups",
                "--no-emit-workspace",
                "--format",
                "pylock.toml",
                "-o",
                str(lock),
            ],
            check=True,
            env=dict(os.environ, UV_NO_CONFIG="1"),
        )
        command = [sys.executable, "-m", "pip_audit", "--cache-dir", str(Path(work) / "cache"), "--locked", work, *argv]
        return subprocess.run(command, check=False).returncode  # nosec B603


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
