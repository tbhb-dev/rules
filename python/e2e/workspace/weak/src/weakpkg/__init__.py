# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Halves and doubles numbers."""


def half(value: int) -> int:
    """Return value halved, rounding down."""
    return value // 2


def double(value: int) -> int:
    """Return value doubled."""
    return value * 2
