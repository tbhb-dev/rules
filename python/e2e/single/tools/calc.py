# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Arithmetic for the report."""


def clamp(value: int, low: int, high: int) -> int:
    """Return value limited to the range [low, high]."""
    return max(low, min(value, high))
