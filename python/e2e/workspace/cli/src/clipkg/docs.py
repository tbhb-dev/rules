# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The docs command."""

from clipkg import gitfiles


def count(listing: str) -> int:
    """Return how many files the docs command looks at."""
    return len(gitfiles.tracked(listing))
