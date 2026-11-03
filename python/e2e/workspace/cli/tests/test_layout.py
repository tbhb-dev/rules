# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from clipkg import layout


def test_count() -> None:
    assert layout.count("b\n\na\n") == 2
