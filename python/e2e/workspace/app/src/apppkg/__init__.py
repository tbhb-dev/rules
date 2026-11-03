# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Summaries built on corepkg."""

import corepkg


def summary(text: str) -> str:
    """Return a one-line summary of text."""
    return f"{corepkg.words(text)} words"
