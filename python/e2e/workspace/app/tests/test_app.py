# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import apppkg


def test_summary() -> None:
    assert apppkg.summary("a b") == "2 words"
