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

Python 3.13 and later, standard library only: it runs on the consumer's
Ansible environment.
"""

import argparse
import os
import shutil
import subprocess  # nosec B404
import sys

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
        }
    )
    return env


def run(command: Sequence[str], env: Mapping[str, str], cwd: Path | None = None) -> int:
    print("ansible_check: running " + " ".join(command), flush=True)
    return subprocess.run(command, env=env, cwd=cwd, check=False).returncode


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
        return run(
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
        )
    env["MOLECULE_EPHEMERAL_DIRECTORY"] = str(tmp / "molecule")
    return run(
        ["molecule", "test", "-s", options.scenario, *extra],
        env,
        cwd=root / options.role,
    )


if __name__ == "__main__":
    sys.exit(main())
