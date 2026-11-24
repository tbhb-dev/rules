# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Dotted integer versions and the bump levels the caller can permit."""

import re

_VERSION = re.compile(r"v?([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?")
COMMIT = re.compile(r"[0-9a-f]{40}")
_LEVELS = ("major", "minor", "patch")


def parse_version(value: str) -> tuple[str, ...] | None:
    match = _VERSION.fullmatch(value)
    if match is None:
        return None
    return tuple((part or "").lstrip("0") or "0" for part in match.groups())


def _sort_key(parts: tuple[str, ...]) -> tuple[tuple[int, str], ...]:
    # Length then digits orders arbitrarily large nonnegative integers.
    return tuple((len(part), part) for part in parts)


def bump(old: str, new: str, allowed: frozenset[str]) -> str | None:
    before, after = parse_version(old), parse_version(new)
    if before is None or after is None:
        return "unparsed_version"
    if _sort_key(after) < _sort_key(before):
        return "downgrade"
    if after == before:
        return "digest_without_version_change"
    level = next(
        level
        for level, left, right in zip(_LEVELS, before, after, strict=True)
        if left != right
    )
    return permit(level, allowed)


def permit(level: str, allowed: frozenset[str]) -> str | None:
    return None if level in allowed else "bump_level_not_allowed"
