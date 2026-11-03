# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Word counts."""


def words(text: str, minimum: int = 1) -> int:
    """Return how many words of at least minimum characters text has."""
    return sum(1 for word in text.split() if len(word) >= minimum)
