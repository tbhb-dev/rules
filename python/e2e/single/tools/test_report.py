# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from tools import report


def test_score() -> None:
    assert report.score(12) == "10/10"
    assert report.score(-3) == "0/10"
