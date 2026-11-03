# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from tools import calc


def test_clamp() -> None:
    assert calc.clamp(-1, 0, 10) == 0
    assert calc.clamp(0, 0, 10) == 0
    assert calc.clamp(10, 0, 10) == 10
    assert calc.clamp(11, 0, 10) == 10
    assert calc.clamp(5, 0, 10) == 5
