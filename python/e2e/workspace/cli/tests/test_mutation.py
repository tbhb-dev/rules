# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from tbhbops import mutation


def test_count() -> None:
    assert mutation.count("b\n\na\n") == 2
