# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A type error only Linux analysis reaches."""

import sys


def value() -> int:
    """Return 1."""
    if sys.platform != "win32":
        return "linux"
    return 1
