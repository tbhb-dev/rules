# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import unittest
from pathlib import Path
from typing import NamedTuple

from repo.private.renovate_approval.decide import REASON_CODES, decide
from repo.private.renovate_approval.matcher import Finding

TESTDATA = Path(__file__).with_name("testdata")


class Case(NamedTuple):
    diff: bytes
    metadata: dict[str, object]
    checks: dict[str, object]
    expected: str


def load_case(name: str) -> Case:
    directory = TESTDATA / name
    metadata = json.loads((directory / "metadata.json").read_bytes())
    checks = json.loads((directory / "checks.json").read_bytes())
    return Case(
        (directory / "diff.patch").read_bytes(),
        metadata,
        checks,
        metadata.pop("expected"),
    )


class TestDecide(unittest.TestCase):
    def test_cases(self) -> None:
        for directory in sorted(TESTDATA.iterdir()):
            with self.subTest(case=directory.name):
                diff, metadata, checks, expected = load_case(directory.name)
                decision = decide(diff, metadata, checks)
                assert decision.reason == expected, decision.findings
                assert decision.approve == (
                    decision.reason == "ok_pin_only" and not decision.findings
                )
                assert decision.approve == (expected == "ok_pin_only")
                if decision.findings:
                    assert decision.findings[0].code == expected

    def test_reason_codes_have_fixtures(self) -> None:
        expected = {
            load_case(directory.name).expected for directory in TESTDATA.iterdir()
        }
        codes = {
            code
            for stage, members in REASON_CODES.items()
            if stage != "other_stages"
            for code in members
        }
        assert codes == expected

    def test_findings_follow_head_lines(self) -> None:
        diff, metadata, checks, _ = load_case("ordering")
        assert decide(diff, metadata, checks).findings == [
            Finding("not_a_pin_line", ".github/workflows/ci.yml", 4, ""),
            Finding("key_changed", ".github/workflows/ci.yml", 6, ""),
        ]

    def test_findings_follow_paths_then_checks(self) -> None:
        diff, metadata, checks, _ = load_case("ordering-by-path")
        checks["runs"] = list[object]()
        decision = decide(diff, metadata, checks)
        assert decision.findings == [
            Finding("not_a_pin_line", ".github/workflows/ci.yml", 4, ""),
            Finding("key_changed", ".github/workflows/zz.yml", 6, ""),
            Finding("check_missing", "", 0, "test"),
        ]

    def test_real_group_refuses_only_preset(self) -> None:
        diff, metadata, checks, _ = load_case("renovate-pr-366")
        assert decide(diff, metadata, checks).findings == [
            Finding("not_a_pin_file", ".github/renovate.json5", 0, "")
        ]

    def test_empty_inputs_refuse(self) -> None:
        assert not decide("", {}, {}).approve


if __name__ == "__main__":
    unittest.main()
