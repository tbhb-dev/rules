# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from tbhbops import docs


def test_count() -> None:
    assert docs.count("b\n\na\n") == 2
