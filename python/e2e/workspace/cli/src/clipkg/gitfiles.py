# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The files a repository tracks."""


def tracked(listing: str) -> list[str]:
    """Return the non-empty lines of a file listing, sorted."""
    return sorted(line for line in listing.splitlines() if line)
