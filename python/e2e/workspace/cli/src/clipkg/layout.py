# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The layout command."""

import sys

from clipkg import gitfiles


def count(listing: str) -> int:
    """Return how many files the layout command looks at."""
    return len(gitfiles.tracked(listing))


def main() -> None:
    """Print the count for the listing on stdin (the clipkg-layout script)."""
    print(count(sys.stdin.read()))
