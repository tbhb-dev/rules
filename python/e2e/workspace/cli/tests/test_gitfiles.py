# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from tbhbops import gitfiles


def test_tracked() -> None:
    assert gitfiles.tracked("b\n\na\n") == ["a", "b"]
