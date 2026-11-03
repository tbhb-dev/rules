# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import corepkg


def test_words() -> None:
    assert corepkg.words("a b  c") == 3
    assert corepkg.words("a bb  ccc", 2) == 2
