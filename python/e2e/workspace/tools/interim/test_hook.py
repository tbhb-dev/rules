# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from tools.interim import hook


def test_trailer() -> None:
    assert hook.trailer("x") == "Assisted-by: x"
