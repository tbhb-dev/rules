# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import unittest

from repo.private.renovate_approval.versions import bump, parse_version, permit


class TestVersions(unittest.TestCase):
    def test_version_rows(self) -> None:
        rows = (
            ("v7", ("7", "0", "0")),
            ("2.09", ("2", "9", "0")),
            ("0.10.12", ("0", "10", "12")),
            ("1.0.0-rc.1", None),
            ("1.0.0+build", None),
            ("1.0.0.1", None),
            ("latest", None),
            ("1" * 101, ("1" * 101, "0", "0")),
            ("\uff11.\uff10.\uff11", None),
        )
        for version, expected in rows:
            with self.subTest(version=version):
                assert parse_version(version) == expected

    def test_bump_rows(self) -> None:
        rows = (
            ("0.99", "1.0", "major", None),
            ("0.99", "1.0", "minor", "bump_level_not_allowed"),
            ("1.9", "1.10", "minor", None),
            ("1.0.9", "1.0.10", "patch", None),
            ("1.2", "v1.2.0", "patch", "digest_without_version_change"),
            ("1.10", "1.9", "minor", "downgrade"),
            ("1.0-rc", "1.0", "minor", "unparsed_version"),
            ("1.0", "1.1+build", "minor", "unparsed_version"),
        )
        for old, new, level, expected in rows:
            with self.subTest(old=old, new=new, level=level):
                assert bump(old, new, frozenset({level})) == expected

    def test_digest_permission(self) -> None:
        assert permit("digest", frozenset({"digest"})) is None
        assert permit("digest", frozenset()) == "bump_level_not_allowed"


if __name__ == "__main__":
    unittest.main()
