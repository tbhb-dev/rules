# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Run one Ansible check in a hermetic environment.

Usage:
    ansible_check.py syntax --inventory PATH PLAYBOOK...
    ansible_check.py lint [--config PATH] [ARG...]
    ansible_check.py molecule [--role DIR] [--scenario NAME] [ARG...]

Started by the checks of tbhb_rules_ansible, through python_tool, at the
root of a test's copy of the tree. The environment it gives the tools:
ANSIBLE_CONFIG names the tree's ansible.cfg (Ansible ignores one in a
world-writable directory and would otherwise look outside the tree), or an
empty config when the tree has none; ANSIBLE_COLLECTIONS_PATH holds only
the pinned collections (TBHB_ANSIBLE_COLLECTIONS), and overrides any
collections_path the config sets; Ansible's home and temporary directories
live under TEST_TMPDIR.

`syntax` lists the inventory with ansible-inventory, failing on any source
it cannot parse, and runs `ansible-playbook --syntax-check` on each
playbook. `lint` runs ansible-lint offline with the tree's own config
(.ansible-lint or .config/ansible-lint.yml), or with --config, or else
with the rules' default (TBHB_ANSIBLE_LINT_DEFAULT_CONFIG), copied to the
tree root as .ansible-lint so its paths resolve there. `molecule` runs
`molecule test` from the role directory.

`lint` runs ansible-lint unbuffered and under a watchdog. The deadline is
80% of Bazel's TEST_TIMEOUT (240 s without it), or the seconds of
TBHB_ANSIBLE_CHECK_TIMEOUT. When it passes, the driver prints the process
table (names only, never command lines, because the logs can be public),
the host's load (uptime and nproc) and the last lines of ansible-lint's
output, kills ansible-lint's process group, and exits 124, so a hung run
names where it stopped instead of dying silently at Bazel's timeout.

Python 3.13 and later, standard library only: it runs on the consumer's
Ansible environment.
"""

import argparse
import contextlib
import os
import shutil
import signal
import subprocess  # nosec B404
import sys
import threading
from collections import deque

# Imported at run time, not under TYPE_CHECKING: the consumer's interpreter
# may be 3.13, which evaluates annotations eagerly.
from collections.abc import Mapping, Sequence  # noqa: TC003
from pathlib import Path

# The configs ansible-lint finds by itself, in the order it looks.
LINT_CONFIGS = (
    ".ansible-lint",
    ".ansible-lint.yml",
    ".ansible-lint.yaml",
    ".config/ansible-lint.yml",
    ".config/ansible-lint.yaml",
)

# The watchdog: the share of Bazel's test timeout it may use, the deadline
# without one, the seconds between SIGTERM and SIGKILL, the exit code of a
# fired watchdog (that of timeout(1)), and how much output to keep.
TIMEOUT_SHARE = 0.8
DEFAULT_TIMEOUT = 240.0
GRACE = 5.0
TIMED_OUT = 124
TAIL_LINES = 20
PS_COLUMNS = "pid,ppid,etime,stat,comm"


def environment(root: Path, tmp: Path, environ: Mapping[str, str]) -> dict[str, str]:
    """The tools' environment, with every Ansible path under `root` or `tmp`."""
    config = root / "ansible.cfg"
    if config.is_file():
        print(f"ansible_check: ANSIBLE_CONFIG is the tree's {config.name}")
    else:
        config = tmp / "ansible.cfg"
        config.write_text("")
        print("ansible_check: the tree has no ansible.cfg; using an empty one")
    collections = [
        p for p in environ.get("TBHB_ANSIBLE_COLLECTIONS", "").split(":") if p
    ]
    if not collections:
        # An empty directory rather than none at all: unset, the path would
        # fall back to the config's and then to the user's home.
        empty = tmp / "collections"
        empty.mkdir(exist_ok=True)
        collections = [str(empty)]
    env = dict(environ)
    env.update(
        {
            "ANSIBLE_CONFIG": str(config),
            "ANSIBLE_COLLECTIONS_PATH": ":".join(collections),
            "ANSIBLE_COLLECTIONS_SCAN_SYS_PATH": "false",
            "ANSIBLE_HOME": str(tmp / "ansible-home"),
            "ANSIBLE_LOCAL_TEMP": str(tmp / "ansible-local"),
            "ANSIBLE_REMOTE_TEMP": str(tmp / "ansible-remote"),
            # Without these, an inventory source no plugin can parse is a
            # warning, and the inventory check passes on a broken file.
            "ANSIBLE_INVENTORY_UNPARSED_FAILED": "true",
            "ANSIBLE_INVENTORY_ANY_UNPARSED_IS_FAILED": "true",
            # ansible-core refuses to start under a locale that is not UTF-8,
            # which is what a test's bare environment can have.
            "PYTHONUTF8": "1",
            # Block-buffered output is lost when Bazel kills a hung test.
            "PYTHONUNBUFFERED": "1",
        }
    )
    return env


def run(command: Sequence[str], env: Mapping[str, str], cwd: Path | None = None) -> int:
    print("ansible_check: running " + " ".join(command), flush=True)
    return subprocess.run(command, env=env, cwd=cwd, check=False).returncode


def seconds(value: str | None) -> float | None:
    """`value` as a positive number of seconds, or None."""
    try:
        number = float(value or "")
    except ValueError:
        return None
    return number if number > 0 else None


def watchdog_timeout(environ: Mapping[str, str]) -> float:
    """The lint deadline: the override, else 80% of TEST_TIMEOUT, else 240 s."""
    override = seconds(environ.get("TBHB_ANSIBLE_CHECK_TIMEOUT"))
    if override is not None:
        return override
    bazel = seconds(environ.get("TEST_TIMEOUT"))
    return DEFAULT_TIMEOUT if bazel is None else bazel * TIMEOUT_SHARE


def process_table() -> str:
    """The process tree by name only: command lines can carry tokens."""
    # --forest is procps; macOS ps rejects it, so fall back to a flat list.
    flat: list[str] = []
    for extra in (["--forest"], flat):
        try:
            done = subprocess.run(  # nosec B603 B607
                ["ps", "-e", "-o", PS_COLUMNS, *extra],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as error:
            return f"ps is unavailable: {error}"
        if done.returncode == 0:
            return done.stdout
    return "ps failed"


def host_load() -> str:
    """The output of `uptime` and `nproc`, saying so when one is missing."""
    lines = []
    for name in ("uptime", "nproc"):
        try:
            done = subprocess.run(  # nosec B603 B607
                [name], capture_output=True, text=True, check=False
            )
        except OSError:
            lines.append(f"{name} unavailable")
        else:
            lines.append(done.stdout.strip())
    return "\n".join(lines)


def run_watched(
    command: Sequence[str],
    env: Mapping[str, str],
    timeout: float,
    cwd: Path | None = None,
) -> int:
    """Run `command`, streaming its output, and kill it after `timeout` seconds.

    The child leads its own process group. On the deadline, before killing,
    print the process table, the load (`uptime`, `nproc`) and the child's
    last lines, then SIGTERM the group, and SIGKILL it after a grace period.
    Returns the child's exit code, or 124 when the watchdog fired.
    """
    print("ansible_check: running " + " ".join(command), flush=True)
    child = subprocess.Popen(  # nosec B603
        command,
        env=env,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        start_new_session=True,
    )
    tail: deque[str] = deque(maxlen=TAIL_LINES)

    def stream() -> None:
        assert child.stdout is not None  # noqa: S101
        for line in child.stdout:
            print(line, end="", flush=True)
            tail.append(line.rstrip("\n"))

    reader = threading.Thread(target=stream, daemon=True)
    reader.start()
    try:
        code = child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Whether ansible-lint prints per-file progress is unverified; if it
        # does, the last lines name the file it hung on.
        print(
            f"ansible_check: watchdog fired after {timeout:g}s, "
            "ansible-lint did not finish\n" + process_table(),
            flush=True,
        )
        print(host_load(), flush=True)
        print("ansible_check: last output lines:", flush=True)
        for line in list(tail):
            print(f"  {line}", flush=True)
        os.killpg(child.pid, signal.SIGTERM)
        with contextlib.suppress(subprocess.TimeoutExpired):
            child.wait(timeout=GRACE)
        # Also reaps members of the group that outlived the leader.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        code = TIMED_OUT
    reader.join(timeout=GRACE)
    return code


def syntax(inventory: str, playbooks: Sequence[str], env: Mapping[str, str]) -> int:
    failed = []
    if run(["ansible-inventory", "--list", "-i", inventory], env):
        failed.append(f"inventory {inventory}")
    failed.extend(
        f"playbook {playbook}"
        for playbook in playbooks
        if run(["ansible-playbook", "--syntax-check", "-i", inventory, playbook], env)
    )
    if failed:
        print("ansible_check: FAIL: " + ", ".join(failed), file=sys.stderr)
        return 1
    print(f"ansible_check: inventory and {len(playbooks)} playbook(s) passed")
    return 0


def lint_config(root: Path, config: str, environ: Mapping[str, str]) -> Path:
    """The ansible-lint config to use, after saying which it is."""
    if config:
        print(f"ansible_check: ansible-lint config: {config} (the check's `config`)")
        return root / config
    for name in LINT_CONFIGS:
        if (root / name).is_file():
            print(f"ansible_check: ansible-lint config: {name} (the tree's own)")
            return root / name
    default = root / LINT_CONFIGS[0]
    shutil.copyfile(environ["TBHB_ANSIBLE_LINT_DEFAULT_CONFIG"], default)
    print("ansible_check: ansible-lint config: tbhb_rules_ansible's default")
    return default


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ansible_check")
    modes = parser.add_subparsers(dest="mode", required=True)
    syntax_mode = modes.add_parser("syntax")
    syntax_mode.add_argument("--inventory", required=True)
    syntax_mode.add_argument("playbooks", nargs="+")
    lint_mode = modes.add_parser("lint")
    lint_mode.add_argument("--config", default="")
    molecule_mode = modes.add_parser("molecule")
    molecule_mode.add_argument("--role", default=".")
    molecule_mode.add_argument("--scenario", default="default")
    options, extra = parser.parse_known_args(argv)

    root = Path.cwd()
    tmp = Path(os.environ["TEST_TMPDIR"])
    env = environment(root, tmp, os.environ)
    if options.mode == "syntax":
        return syntax(options.inventory, [*options.playbooks, *extra], env)
    if options.mode == "lint":
        config = lint_config(root, options.config, os.environ)
        return run_watched(
            [
                "ansible-lint",
                "--offline",
                "--project-dir",
                ".",
                "-c",
                str(config),
                *extra,
            ],
            env,
            watchdog_timeout(os.environ),
        )
    env["MOLECULE_EPHEMERAL_DIRECTORY"] = str(tmp / "molecule")
    return run(
        ["molecule", "test", "-s", options.scenario, *extra],
        env,
        cwd=root / options.role,
    )


if __name__ == "__main__":
    sys.exit(main())
