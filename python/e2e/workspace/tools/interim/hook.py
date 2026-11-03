# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""An interim hook, kept apart from clipkg."""


def trailer(name: str) -> str:
    """Return a commit trailer naming name."""
    return f"Assisted-by: {name}"
