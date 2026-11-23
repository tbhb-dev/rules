# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import subprocess
import sys
from io import StringIO

import pytest
from hypothesis import given
from hypothesis import strategies as st

from lint.private.commit_identity import check_trailers as ai

H = "sha-256-64:"
ROOT = H + "a" * 16
CHILD = H + "c" * 16
GOOD = f"harness=claude-code:2.1;model=anthropic:m;session={ROOT}"
MERGED = "Merged-by: LLM harness=codex;model=openai:m"


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
        ("LLM harness=codex;color=red", "model required"),
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
    assert ai.check_pair("model=a b") == "bad attribute 'model=a b'"
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


def test_agent_merge_accepts_optional_and_repeated_merged_by() -> None:
    message = f"Merge topic\n\nGenerated-by: LLM {GOOD}\nAssisted-by: LLM {GOOD}"
    for trailers in ("", f"\n{MERGED}", f"\n{MERGED}\nMerged-by: LLM {GOOD}"):
        assert ai.check_agent_message(message + trailers, merge=True) == []


def test_merged_by_does_not_supply_agent_authorship() -> None:
    assert ai.check_agent_message(MERGED, merge=True) == [
        "missing Generated-by or Assisted-by trailer"
    ]


@pytest.mark.parametrize("key", ["Generated-by", "Assisted-by"])
def test_merged_by_must_follow_authorship(key: str) -> None:
    line = f"{key}: LLM {GOOD}"
    assert ai.check_message(f"{MERGED}\n{line}", merge=True) == [
        f"{line}: Merged-by must come after Generated-by and Assisted-by"
    ]


@pytest.mark.parametrize(
    ("value", "problem"),
    [
        ("tool harness=codex;model=m", "must start with literal LLM"),
        ("LLM model=m;harness=codex", "attributes out of order or duplicated"),
        (
            "LLM harness=codex;model=m;started_at=2025-01-01T00:05:01Z",
            "started_at is more than 300 seconds after the committer date",
        ),
    ],
)
def test_merged_by_checks_each_value(value: str, problem: str) -> None:
    line = f"Merged-by: {value}"
    assert ai.check_message(f"{MERGED}\n{line}", 1735689600, merge=True) == [
        f"{line}: {problem}"
    ]


@pytest.mark.parametrize("key", ["merged-by", "Merge-by"])
def test_merged_by_key_is_exact(key: str) -> None:
    assert ai.check_message(f"{key}: nope") == []


@given(
    st.lists(
        st.sampled_from(
            [
                "effort",
                "harness",
                "launch",
                "model",
                "session",
                "started_at",
                "subagent",
                "surface",
            ]
        ),
        unique=True,
        min_size=1,
    )
)
def test_check_value_order_property(keys: list[str]) -> None:
    samples = {
        "effort": "low",
        "harness": "codex",
        "launch": ROOT,
        "model": "openai:m",
        "session": ROOT,
        "started_at": "2025-01-01T00:00:00Z",
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


@pytest.mark.parametrize(
    ("args", "status", "output"),
    [
        ([], 1, f"{MERGED}: Merged-by is valid only on merge commits\n"),
        (["--merge"], 0, ""),
        (["1735689600", "--merge"], 0, ""),
    ],
)
def test_cli_merge(
    args: list[str],
    status: int,
    output: str,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    message = f"Generated-by: LLM {GOOD}\n{MERGED}"
    monkeypatch.setattr(ai.sys, "stdin", StringIO(message))
    assert ai.cli(args) == status
    assert capsys.readouterr() == (output, "")


@pytest.mark.parametrize(
    ("blob", "status", "problem"),
    [
        ("color=red;harness=codex;model=m", 0, ""),
        (
            "color=red;effort=huge;harness=codex;model=m",
            1,
            "bad effort huge",
        ),
    ],
)
def test_unknown_attribute_warns(blob: str, status: int, problem: str) -> None:
    line = f"Generated-by: LLM {blob}"
    result = subprocess.run(
        [sys.executable, ai.__file__],
        input=line,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status
    assert result.stdout == (f"{line}: {problem}\n" if problem else "")
    assert result.stderr == "::warning::unknown attribute color\n"


@pytest.mark.parametrize("value", [ROOT, H + "0123456789abcdef", H + "0" * 16])
def test_launch_accepts(value: str) -> None:
    assert ai.check_pair(f"launch={value}") is None


@pytest.mark.parametrize(
    "value",
    [
        "nope",
        "sha256:0123456789abcdef",
        H + "a" * 15,
        H + "a" * 17,
        H + "ABCDEF0123456789",
        H + "g" * 16,
        "SHA-256-64:0123456789abcdef",
    ],
)
def test_launch_rejects(value: str) -> None:
    assert ai.check_pair(f"launch={value}") == "bad launch hash"


@pytest.mark.parametrize(
    "value",
    [
        "2025-01-01T00:00:00Z",
        "2024-02-29T23:59:59Z",
        "2000-02-29T12:34:56Z",
        "0001-01-01T00:00:00Z",
        "9999-12-31T23:59:59Z",
    ],
)
def test_started_at_accepts(value: str) -> None:
    assert ai.check_pair(f"started_at={value}") is None


@pytest.mark.parametrize(
    "value",
    [
        "2025-01-01",
        "20250101T000000Z",
        "2025-1-01T00:00:00Z",
        "2025-01-1T00:00:00Z",
        "2025-01-01T0:00:00Z",
        "2025-01-01T00:0:00Z",
        "2025-01-01T00:00:0Z",
        "2025-01-01T00:00:00",
        "2025-01-01T00:00:00+00:00",
        "2025-01-01T00:00:00-05:00",
        "2025-01-01T00:00:00.1Z",
        "2025-01-01T00:00:00.000Z",
        "2025-01-01t00:00:00Z",
        "2025-01-01T00:00:00z",
        "2025-13-01T00:00:00Z",
        "2025-00-01T00:00:00Z",
        "2025-02-30T00:00:00Z",
        "2025-02-29T00:00:00Z",
        "1900-02-29T00:00:00Z",
        "2025-01-00T00:00:00Z",
        "2025-04-31T00:00:00Z",
        "2025-01-01T24:00:00Z",
        "2025-01-01T00:60:00Z",
        "2025-01-01T00:00:60Z",
        "0000-01-01T00:00:00Z",
        "\uff12\uff10\uff12\uff15-01-01T00:00:00Z",
        "2025-01-01X00:00:00Z",
        "2025-01-01T00:00:00ZZ",
    ],
)
def test_started_at_rejects(value: str) -> None:
    assert ai.check_pair(f"started_at={value}") == "bad started_at"


@pytest.mark.parametrize("key", ["launch", "started_at"])
@pytest.mark.parametrize("value", ["", "a b", "a,b", "a;b"])
def test_new_attribute_syntax(key: str, value: str) -> None:
    pair = f"{key}={value}"
    assert ai.check_pair(pair) == f"bad attribute {pair!r}"


@pytest.mark.parametrize(
    "blob",
    [
        f"harness=codex;model=m;launch={ROOT}",
        f"harness=codex;launch={ROOT};launch={ROOT};model=m",
        f"{GOOD};started_at=2025-01-01T00:00:00Z;started_at=2025-01-01T00:00:00Z",
        f"{GOOD};surface=cli;started_at=2025-01-01T00:00:00Z",
        f"harness=codex;model=m;started_at=2025-01-01T00:00:00Z;session={ROOT}",
        f"{GOOD};subagent={CHILD};started_at=2025-01-01T00:00:00Z",
    ],
)
def test_new_attribute_order_rejects(blob: str) -> None:
    assert ai.check_value(f"LLM {blob}") == "attributes out of order or duplicated"


def test_old_and_new_attributes_together() -> None:
    assert (
        ai.check_value(
            f"LLM effort=high;harness=codex:1;launch={ROOT};model=openai:m;"
            f"session={ROOT};started_at=2025-01-01T00:00:00Z;subagent={CHILD};surface=cli"
        )
        is None
    )


@pytest.mark.parametrize(
    ("value", "committer_time", "problem"),
    [
        ("2025-01-01T00:00:00Z", 1735689600, None),
        ("2025-01-01T00:05:00Z", 1735689600, None),
        (
            "2025-01-01T00:05:01Z",
            1735689600,
            "started_at is more than 300 seconds after the committer date",
        ),
        ("2024-12-31T00:00:00Z", 1735689600, None),
        ("9999-12-31T23:59:59Z", None, None),
        ("2025-01-01T00:05:01Z", None, None),
        (
            "1970-01-01T00:05:01Z",
            0,
            "started_at is more than 300 seconds after the committer date",
        ),
    ],
)
def test_started_at_skew(
    value: str, committer_time: int | None, problem: str | None
) -> None:
    line = f"Generated-by: LLM {GOOD};started_at={value}"
    assert ai.check_agent_message(line, committer_time) == (
        [] if problem is None else [f"{line}: {problem}"]
    )


def test_started_at_checks_each_line() -> None:
    first = f"Generated-by: LLM {GOOD};started_at=2025-01-01T00:05:00Z"
    second = f"Assisted-by: LLM {GOOD};started_at=2025-01-01T00:05:01Z"
    assert ai.check_agent_message(f"{first}\n{second}", 1735689600) == [
        f"{second}: started_at is more than 300 seconds after the committer date"
    ]


@pytest.mark.parametrize("committer_time", [None, 1735689600])
def test_main_started_at(
    committer_time: int | None,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    line = f"Generated-by: LLM {GOOD};started_at=2025-01-01T00:05:01Z"
    monkeypatch.setattr(ai.sys, "stdin", StringIO(line))
    assert ai.main(committer_time) == int(committer_time is not None)
    expected = (
        ""
        if committer_time is None
        else f"{line}: started_at is more than 300 seconds after the committer date\n"
    )
    assert capsys.readouterr() == (expected, "")


@pytest.mark.parametrize(
    ("args", "timestamp", "status"),
    [
        ([], "2025-01-01T00:05:01Z", 0),
        (["1735689600"], "2025-01-01T00:05:00Z", 0),
        (["1735689600"], "2025-01-01T00:05:01Z", 1),
        (["0"], "1970-01-01T00:05:00Z", 0),
        (["0"], "1970-01-01T00:05:01Z", 1),
        (["-1"], "1970-01-01T00:05:00Z", 1),
    ],
)
def test_cli_started_at(
    args: list[str],
    timestamp: str,
    status: int,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    line = f"Generated-by: LLM {GOOD};started_at={timestamp}"
    expected = (
        ""
        if status == 0
        else f"{line}: started_at is more than 300 seconds after the committer date\n"
    )
    monkeypatch.setattr(ai.sys, "stdin", StringIO(line))
    assert ai.cli(args) == status
    assert capsys.readouterr() == (expected, "")
    result = subprocess.run(
        [sys.executable, ai.__file__, *args],
        input=line,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status
    assert result.stderr == ""
    assert result.stdout == expected


@pytest.mark.parametrize(
    ("args", "problem"),
    [
        ([""], "bad committer date argument: ''"),
        (["nope"], "bad committer date argument: 'nope'"),
        (["bad\ndate"], "bad committer date argument: 'bad\\ndate'"),
        (["1", "2"], "expected at most one committer date argument"),
        (["1", "2", "3"], "expected at most one committer date argument"),
    ],
    ids=["empty", "non_integer", "multiline", "extra", "two_extra"],
)
def test_cli_bad_committer_date(
    args: list[str],
    problem: str,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(ai.sys, "stdin", StringIO(f"Generated-by: LLM {GOOD}"))
    assert ai.cli(args) == 1
    assert capsys.readouterr() == (f"{problem}\n", "")
    result = subprocess.run(
        [sys.executable, ai.__file__, *args],
        input=f"Generated-by: LLM {GOOD}",
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert result.stdout == f"{problem}\n"
    assert result.stderr == ""


def test_check_pair_warns_on_stderr_in_process(
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert ai.check_pair("color=red") is None
    captured = capsys.readouterr()
    assert captured.err == "::warning::unknown attribute color\n"
    assert captured.out == ""
    assert ai.check_pair("effort=max") is None
    assert capsys.readouterr().err == ""
    assert ai.check_pair("model=a=b") is None
    assert capsys.readouterr().err == ""
