# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from io import StringIO

import pytest
from hypothesis import given
from hypothesis import strategies as st

from lint.private.commit_identity import check_trailers as ai

H = "sha-256-64:"
ROOT = H + "a" * 16
CHILD = H + "c" * 16
GOOD = f"harness=claude-code:2.1;model=anthropic:m;session={ROOT}"


@pytest.mark.parametrize(
    "value",
    [
        "LLM harness=claude-code;model=anthropic:m",
        (
            "LLM effort=max;harness=codex:1;model=openai:gpt-5;"
            f"session={ROOT};subagent={CHILD};surface=cli"
        ),
        f"LLM {GOOD}",
        "LLM harness=antigravity;model=gcp.gemini:m;surface=cli",
        "LLM harness=codex;model=openai:m some prose",
    ],
)
def test_check_value_accepts(value: str) -> None:
    assert ai.check_value(value) is None


@pytest.mark.parametrize(
    ("value", "problem"),
    [
        ("", "must start with literal LLM"),
        ("harness=codex", "must start with literal LLM"),
        ("llm harness=codex", "must start with literal LLM"),
        ("LLM", "need exactly one attribute blob"),
        ("LLM a=b c=d", "need exactly one attribute blob"),
        ("LLM harness=codex;", "bad attribute ''"),
        ("LLM harness=codex;Bad=1", "bad attribute 'Bad=1'"),
        ("LLM harness=codex;color=red", "unknown attribute color"),
        ("LLM effort=huge;harness=codex", "bad effort huge"),
        ("LLM harness=codex;session=nope", "bad session hash"),
        (f"LLM harness=codex;session={ROOT};subagent=x", "bad subagent hash"),
        ("LLM harness=cursor", "unknown harness cursor"),
        ("LLM effort=low", "harness required"),
        ("LLM model=a:b;harness=codex", "attributes out of order or duplicated"),
        ("LLM harness=codex;harness=codex", "model required"),
        (
            "LLM harness=codex;harness=codex;model=a:b",
            "attributes out of order or duplicated",
        ),
        ("LLM harness=claude-code", "model required"),
        ("LLM harness=claude-code:2.1;surface=cli", "model required"),
        ("LLM harness=codex:1;surface=cli", "model required"),
        ("LLM harness=antigravity", "model required"),
        ("LLM harness=codex;model=", "bad attribute 'model='"),
    ],
)
def test_check_value_rejects(value: str, problem: str) -> None:
    assert ai.check_value(value) == problem


def test_check_pair() -> None:
    assert ai.check_pair("harness=codex") is None
    assert ai.check_pair("surface=a:b/c") is None
    assert ai.check_pair("harness=") == "bad attribute 'harness='"
    assert ai.check_pair("=x") == "bad attribute '=x'"
    assert ai.check_pair("a=b=c") is not None
    for effort in ai.EFFORTS:
        assert ai.check_pair(f"effort={effort}") is None
    assert ai.check_pair("subagent=sha-256-64:ABCDEF0123456789") == "bad subagent hash"
    assert ai.check_pair("session=sha-256-64:" + "a" * 17) == "bad session hash"
    assert ai.check_pair("harness=codex:1:2") is None


def test_check_message_orders_and_signoff() -> None:
    gen, assist = f"Generated-by: LLM {GOOD}", f"Assisted-by: LLM {GOOD}"
    assert ai.check_message(f"s\n\n{gen}\n{assist}\n") == []
    assert ai.check_message(f"s\n\n{assist}\n{gen}\n") == [
        f"{gen}: Generated-by must come before Assisted-by"
    ]
    assert ai.check_message(f"s\n\n{gen}\n{gen}\n{assist}\n{assist}\n") == []
    assert ai.check_message("s\n\nGenerated-by: nope\n") == [
        "Generated-by: nope: must start with literal LLM"
    ]
    # Sign-off and co-author trailers are not checked, for anyone.
    assert (
        ai.check_message(
            f"s\n\n{gen}\nSigned-off-by: H <h@x>\nCo-authored-by: C <c@x>\n"
        )
        == []
    )
    assert ai.check_message("Generated-by:LLM harness=codex;model=m\n") == []
    assert ai.check_message("  Generated-by: nope\n") == []
    assert ai.check_message("") == []


@given(
    st.lists(
        st.sampled_from(
            ["effort", "harness", "model", "session", "subagent", "surface"]
        ),
        unique=True,
        min_size=1,
    )
)
def test_check_value_order_property(keys: list[str]) -> None:
    samples = {
        "effort": "low",
        "harness": "codex",
        "model": "openai:m",
        "session": ROOT,
        "subagent": CHILD,
        "surface": "cli",
    }
    ordered = [k for k in ai.ATTR_ORDER if k in keys]
    value = "LLM " + ";".join(f"{k}={samples[k]}" for k in ordered)
    expected = None
    if "harness" not in keys:
        expected = "harness required"
    elif "model" not in keys:
        expected = "model required"
    assert ai.check_value(value) == expected
    shuffled = "LLM " + ";".join(f"{k}={samples[k]}" for k in reversed(ordered))
    if len(ordered) > 1 and {"harness", "model"} <= set(keys):
        assert ai.check_value(shuffled) == "attributes out of order or duplicated"


def test_check_pair_splits_at_the_first_equals_sign() -> None:
    assert ai.check_pair("model=a=b") is None
    assert ai.check_pair("model=a=b=c") is None
    assert ai.check_pair("harness=codex:1:2") is None
    assert ai.check_pair("harness=x:codex") == "unknown harness x:codex"


def test_check_value_splits_keys_at_the_first_equals_sign() -> None:
    assert ai.check_value("LLM harness=codex;model=a=b") is None
    assert ai.check_value("LLM harness=codex;model=a=b;surface=c=d") is None
    # Splitting at the last "=" would read these keys as surface=a and
    # surface=b and miss the duplicate.
    assert (
        ai.check_value("LLM harness=codex;model=m;surface=a=1;surface=b=1")
        == "attributes out of order or duplicated"
    )


def test_check_messages_are_exact() -> None:
    for line in ("Signed-off-by: A <a@b.c>", "Co-authored-by: A <a@b.c>"):
        assert ai.check_message(f"{line}\n") == []
    assert ai.check_value("LLM harness=codex;model=m") is None


@pytest.mark.parametrize(
    ("message", "problems"),
    [
        ("subject", ["missing Generated-by or Assisted-by trailer"]),
        ("generated-by: nope", ["missing Generated-by or Assisted-by trailer"]),
        (f"Assisted-by: LLM {GOOD}", []),
        (
            "Signed-off-by: A <a@b.c>\nco-authored-by: C <c@d.e>",
            [
                "missing Generated-by or Assisted-by trailer",
                (
                    "Signed-off-by: A <a@b.c>: Signed-off-by and Co-authored-by "
                    "are forbidden for agent commits"
                ),
                (
                    "co-authored-by: C <c@d.e>: Signed-off-by and Co-authored-by "
                    "are forbidden for agent commits"
                ),
            ],
        ),
        (
            f"Generated-by: LLM {GOOD}\nsIgNeD-oFf-By \t: A <a@b.c>",
            [
                (
                    "sIgNeD-oFf-By \t: A <a@b.c>: Signed-off-by and Co-authored-by "
                    "are forbidden for agent commits"
                ),
            ],
        ),
        (f"Generated-by: LLM {GOOD}\n Signed-off-by: A <a@b.c>", []),
        (f"Generated-by: LLM {GOOD}\nx\u2028Signed-off-by: A <a@b.c>", []),
        ("Generated-by: nope", ["Generated-by: nope: must start with literal LLM"]),
    ],
)
def test_agent_message(message: str, problems: list[str]) -> None:
    assert ai.check_agent_message(message) == problems


@pytest.mark.parametrize(
    ("text", "status", "output"),
    [
        (f"Generated-by: LLM {GOOD}", 0, ""),
        ("subject", 1, "missing Generated-by or Assisted-by trailer\n"),
        (
            "Generated-by: nope\nAssisted-by: nope",
            1,
            (
                "Generated-by: nope: must start with literal LLM\n"
                "Assisted-by: nope: must start with literal LLM\n"
            ),
        ),
    ],
)
def test_main(
    text: str,
    status: int,
    output: str,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(ai.sys, "stdin", StringIO(text))
    assert ai.main() == status
    assert capsys.readouterr() == (output, "")
