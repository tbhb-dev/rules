# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The mutation command."""

from clipkg import gitfiles


def count(listing: str) -> int:
    """Return how many files the mutation command looks at."""
    return len(gitfiles.tracked(listing))
