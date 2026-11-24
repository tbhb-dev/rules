# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import unittest
from typing import cast

from repo.private.renovate_approval.test_gather import BASE, HEAD, Replay, cases


class TestApprove(unittest.TestCase):
    def test_recorded_cases(self) -> None:
        for name, case in cases("approve").items():
            with self.subTest(case=name):
                replay = Replay(case)
                result = replay.verify()
                findings = cast("list[dict[str, str]]", result.report["findings"])
                assert [finding["code"] for finding in findings[1:]] == case.get(
                    "additional", []
                )
                for review in replay.posted:
                    assert review["event"] == "APPROVE"
                    assert review["commit_id"] == HEAD
                    assert json.loads(str(review["body"]).splitlines()[1]) == {
                        "head": HEAD,
                        "base": {
                            "repository_id": 17,
                            "ref": "main",
                            "merge_base": BASE,
                        },
                    }


if __name__ == "__main__":
    unittest.main()
