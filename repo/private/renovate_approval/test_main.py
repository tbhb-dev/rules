# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest.mock import patch

from repo.private.renovate_approval.__main__ import main
from repo.private.renovate_approval.decide import REASON_CODES
from repo.private.renovate_approval.test_gather import BASE, HEAD, Replay, cases


class TestMain(unittest.TestCase):
    def test_recorded_cases(self) -> None:
        for name, case in cases("main").items():
            with self.subTest(case=name):
                result = Replay(case).verify()
                assert result.summary.startswith(
                    "existing summary\n## Renovate auto-approval\n"
                )
                assert f"reason={case['reason']}" in result.outputs.splitlines()
                assert result.outputs.startswith("existing=true\n")
                if name == "artifact-and-outputs":
                    assert result.report["decision"] == "approve"
                    assert result.report["pull_request"] == 42
                    assert result.report["head_sha"] == HEAD
                    assert result.report["ci_run_id"] == 21
                    assert result.report["ci_run_attempt"] == 2
                    assert result.report["base_snapshot"] == {
                        "repository_id": 17,
                        "ref": "main",
                        "merge_base": BASE,
                    }
                    assert f"head_sha={HEAD}" in result.outputs.splitlines()

    def test_unavailable_report_destinations(self) -> None:
        for name, case in cases("emit").items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                env = {"RA_MODE": str(case["mode"])}
                if case["destinations"] == "blocked":
                    path = Path(directory) / "file"
                    path.touch()
                    env.update(RA_OUTPUT_DIR=str(path), GITHUB_OUTPUT=directory)
                with patch("sys.stderr") as stderr:
                    assert main(env) == 0
                    assert stderr.write.called == (case["destinations"] == "blocked")

    def test_gather_and_snapshot_codes_have_cases(self) -> None:
        expected = {
            str(case["reason"])
            for group in ("gather", "approve", "main")
            for case in cases(group).values()
        } | {
            reason
            for case in cases("approve").values()
            for reason in cast("list[str]", case.get("additional", []))
        }
        required = {*REASON_CODES["other_stages"], *REASON_CODES["pin_evidence"]}
        assert not required - expected


if __name__ == "__main__":
    unittest.main()
