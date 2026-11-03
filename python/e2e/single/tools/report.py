# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Formats a clamped score."""

from tools import calc


def score(value: int) -> str:
    """Return the score of value out of 10."""
    return f"{calc.clamp(value, 0, 10)}/10"
