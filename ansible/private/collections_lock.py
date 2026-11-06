# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Lock, or check the lock of, the Galaxy collections requirements.yml pins.

Usage: collections_lock.py --requirements PATH --lock PATH [--check]

requirements.yml lists each collection with its `name`, one exact
`version` and `source: https://galaxy.ansible.com/api/`; a range, a missing
version, another source or a role is an error. Renovate looks a collection
up at its `source`, and without /api/ Galaxy answers with its web page. The lock,
requirements.lock.json beside it, records for each collection its version
and Galaxy's download URL and sha256, which tbhb_rules_ansible fetches the
tarball by.

Without --check it asks Galaxy's v3 API for each collection's version
(metadata only: no tarball is downloaded, unpacked or run) and writes the
lock, with sorted keys and a trailing newline, so a rerun with the same
pins rewrites the same bytes. Relative paths are taken from
BUILD_WORKSPACE_DIRECTORY when `bazel run` sets it. With --check it
compares the two files without the network and fails, naming the command
that fixes it, when they disagree.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import cast

import yaml

GALAXY = "https://galaxy.ansible.com/api/"
VERSION_URL = (
    GALAXY + "v3/plugin/ansible/content/published/collections/index/"
    "{namespace}/{name}/versions/{version}/"
)
LOCK_COMMAND = "bazelisk run @tbhb_rules_ansible//:lock"
NAME = re.compile(r"^[a-z0-9_]+\.[a-z0-9_]+$")
# Semantic versioning, which Galaxy requires of every collection version.
EXACT = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
KEYS = frozenset({"name", "version", "source", "type"})
TIMEOUT = 60

type Pins = dict[str, str]
type Lock = dict[str, dict[str, str]]
type Fetch = Callable[[str], object]


class LockError(Exception):
    """requirements.yml, the lock or Galaxy's answer is not what it must be."""


def entry_pin(entry: object) -> tuple[str, str]:
    """The name and version of one `collections` entry."""
    if not isinstance(entry, dict):
        msg = (
            f"{entry!r}: give each collection as a mapping with name, version"
            " and source"
        )
        raise LockError(msg)
    fields = cast("dict[str, object]", entry)
    name = fields.get("name")
    if not isinstance(name, str) or not NAME.match(name):
        msg = f"{name!r} is not a collection name such as ansible.posix"
        raise LockError(msg)
    unknown = sorted(set(fields) - KEYS)
    if unknown:
        msg = f"{name}: unsupported keys {', '.join(unknown)}"
        raise LockError(msg)
    version = fields.get("version")
    if not isinstance(version, str) or not EXACT.match(version):
        msg = (
            f"{name}: version {version!r} is not one exact version such as"
            " 1.2.3; ranges are not allowed"
        )
        raise LockError(msg)
    if fields.get("source") != GALAXY:
        msg = f"{name}: source must be {GALAXY}, not {fields.get('source')!r}"
        raise LockError(msg)
    if fields.get("type", "galaxy") != "galaxy":
        msg = f"{name}: type must be galaxy, not {fields['type']!r}"
        raise LockError(msg)
    return name, version


def read_pins(path: Path) -> Pins:
    """The exact pins of requirements.yml, by collection name."""
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        msg = f"{path}: expected a mapping with a `collections` list"
        raise LockError(msg)
    fields = cast("dict[str, object]", document)
    if fields.get("roles"):
        msg = f"{path}: roles are not supported; only collections are pinned"
        raise LockError(msg)
    entries = fields.get("collections")
    if not isinstance(entries, list) or not entries:
        msg = f"{path}: expected a non-empty `collections` list"
        raise LockError(msg)
    pins: Pins = {}
    for entry in cast("list[object]", entries):
        name, version = entry_pin(entry)
        if name in pins:
            msg = f"{path}: {name} is listed more than once"
            raise LockError(msg)
        pins[name] = version
    return pins


def galaxy_get(url: str) -> object:
    request = urllib.request.Request(  # noqa: S310 - the URL is always GALAXY's
        url,
        headers={"Accept": "application/json", "User-Agent": "tbhb_rules_ansible-lock"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310 # nosec B310
            return cast("object", json.load(response))
    except urllib.error.URLError as error:
        msg = f"{url}: {error}"
        raise LockError(msg) from error


def lock_entry(name: str, version: str, fetch: Fetch) -> dict[str, str]:
    """The lock entry of one pin, from Galaxy's metadata."""
    namespace, _, collection = name.partition(".")
    answer = fetch(
        VERSION_URL.format(namespace=namespace, name=collection, version=version)
    )
    if not isinstance(answer, dict):
        msg = f"{name} {version}: Galaxy's answer is not a JSON object"
        raise LockError(msg)
    fields = cast("dict[str, object]", answer)
    artifact = fields.get("artifact")
    sha256 = (
        cast("dict[str, object]", artifact).get("sha256")
        if isinstance(artifact, dict)
        else None
    )
    url = fields.get("download_url")
    if not isinstance(sha256, str) or not SHA256.match(sha256):
        msg = f"{name} {version}: Galaxy gave no sha256 for the artifact"
        raise LockError(msg)
    if not isinstance(url, str) or not url.startswith("https://"):
        msg = f"{name} {version}: Galaxy gave no https download URL"
        raise LockError(msg)
    return {"sha256": sha256, "url": url, "version": version}


def render(lock: Lock) -> str:
    return json.dumps({"collections": lock}, indent=2, sort_keys=True) + "\n"


def check(pins: Pins, path: Path) -> list[str]:
    """How the lock at `path` disagrees with `pins`, or [] when it does not."""
    if not path.is_file():
        return [f"{path} does not exist"]
    document = cast("object", json.loads(path.read_text(encoding="utf-8")))
    collections = (
        cast("dict[str, object]", document).get("collections")
        if isinstance(document, dict)
        else None
    )
    if not isinstance(collections, dict):
        return [f"{path}: expected a `collections` object"]
    locked = cast("dict[str, object]", collections)
    problems = [
        f"{name} is pinned but not locked" for name in sorted(set(pins) - set(locked))
    ]
    problems += [
        f"{name} is locked but not pinned" for name in sorted(set(locked) - set(pins))
    ]
    for name in sorted(set(pins) & set(locked)):
        entry = locked[name]
        fields = cast("dict[str, object]", entry) if isinstance(entry, dict) else {}
        if fields.get("version") != pins[name]:
            locked_at = fields.get("version")
            problems.append(
                f"{name} is pinned at {pins[name]} but locked at {locked_at!r}"
            )
        elif not (
            isinstance(fields.get("sha256"), str) and isinstance(fields.get("url"), str)
        ):
            problems.append(f"{name} has no url and sha256 in the lock")
    return problems


def resolve(path: str) -> Path:
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    return Path(workspace, path) if workspace else Path(path)


def main(argv: Sequence[str] | None = None, fetch: Fetch = galaxy_get) -> int:
    parser = argparse.ArgumentParser(prog="collections_lock")
    parser.add_argument("--requirements", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args(argv)
    if not options.requirements:
        print(
            "collections_lock: no collections to lock: declare "
            "ansible.collections(requirements = ..., lock = ...) in the root"
            " MODULE.bazel",
            file=sys.stderr,
        )
        return 1
    requirements = resolve(options.requirements)
    lock_path = resolve(options.lock)
    try:
        pins = read_pins(requirements)
        if options.check:
            problems = check(pins, lock_path)
            if problems:
                print(
                    f"collections_lock: FAIL: {lock_path} does not match"
                    f" {requirements}:\n  "
                    + "\n  ".join(problems)
                    + f"\nRun `{LOCK_COMMAND}` from the repository root and"
                    " commit the result.",
                    file=sys.stderr,
                )
                return 1
            print(
                f"collections_lock: {lock_path} matches {requirements}"
                f" ({len(pins)} collections)"
            )
            return 0
        lock = {
            name: lock_entry(name, version, fetch)
            for name, version in sorted(pins.items())
        }
    except LockError as error:
        print(f"collections_lock: FAIL: {error}", file=sys.stderr)
        return 1
    # LF on every platform, so the bytes do not depend on who ran it.
    lock_path.write_text(render(lock), encoding="utf-8", newline="\n")
    print(f"collections_lock: wrote {lock_path} ({len(lock)} collections)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
