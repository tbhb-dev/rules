# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The layout command."""

from tbhbops import gitfiles


def count(listing: str) -> int:
    """Return how many files the layout command looks at."""
    return len(gitfiles.tracked(listing))
