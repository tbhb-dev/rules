# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import difflib
import random
import re
import unittest
from typing import cast

from repo.private.renovate_approval.decide import decide
from repo.private.renovate_approval.test_decide import load_case

MUTATION_CASES = (
    ("workflow-tag-patch", ".github/workflows/ci.yml", r"b{40}|v7\.0\.2"),
    ("git-override", "MODULE.bazel", r"b{40}"),
    ("archive-patch", "MODULE.bazel", r"0\.7\.3|2{64}"),
    ("bazel-patch-replace-keys", "MODULE.bazel", r"0\.10\.1"),
    ("mise-inline", "mise.toml", r"0\.5\.12"),
)


def _patch(path: str, base: str, head: str) -> str:
    return (
        f"diff --git a/{path} b/{path}\n"
        f"index {'1' * 40}..{'2' * 40} 100644\n"
        + "".join(
            difflib.unified_diff(
                base.splitlines(keepends=True),
                head.splitlines(keepends=True),
                f"a/{path}",
                f"b/{path}",
                n=0,
            )
        )
    )


class TestMatcher(unittest.TestCase):
    def test_seeded_non_value_mutations(self) -> None:
        rng = random.Random(431229)  # noqa: S311 - reproducible test sampling
        for case, path, slots in MUTATION_CASES:
            diff, metadata, checks, _ = load_case(case)
            assert decide(diff, metadata, checks).approve
            texts = cast("dict[str, dict[str, str]]", metadata["texts"])
            base, head = texts[path]["base"], texts[path]["head"]
            offsets = {
                index
                for match in re.finditer(slots, head)
                for index in range(*match.span())
            }
            positions = [
                index
                for index, char in enumerate(head)
                if index not in offsets and char.isascii() and char != "\n"
            ]
            for index, replacement in zip(
                rng.sample(positions, min(32, len(positions))),
                rng.choices("xyz #=\t?", k=min(32, len(positions))),
                strict=True,
            ):
                with self.subTest(case=case, index=index):
                    changed = replacement if head[index] != replacement else "!"
                    mutant = head[:index] + changed + head[index + 1 :]
                    texts[path]["head"] = mutant
                    patch = _patch(path, base, mutant) + "".join(
                        _patch(other, text["base"], text["head"])
                        for other, text in texts.items()
                        if other != path
                    )
                    decision = decide(patch, metadata, checks)
                    assert not decision.approve, mutant
                    assert decision.reason != "ok_pin_only"
                    assert decision.findings

    def test_invalid_unicode_in_text_and_patch(self) -> None:
        diff, metadata, checks, _ = load_case("workflow-tag-patch")
        assert decide(chr(0xD800), metadata, checks).reason == "encoding"
        texts = cast("dict[str, dict[str, str]]", metadata["texts"])
        texts[".github/workflows/ci.yml"]["head"] += chr(0xD800)
        assert decide(diff, metadata, checks).reason == "encoding"


if __name__ == "__main__":
    unittest.main()
