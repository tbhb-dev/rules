# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Check pull request text and, when supplied, evidence for the exact head."""

import argparse
import json
import os
import re
import sys
import tomllib
from pathlib import Path
from typing import cast

from jsonschema import Draft202012Validator, ValidationError

SCHEMA = Path(__file__).parents[3] / "repo/baseline/definition-of-done.schema.json"
HEADING = re.compile(r"^ {0,3}(#{1,2})[\t ]+(.+?)\s*(?:\s+#+\s*)?$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", flags=re.DOTALL)
SUCCESS_VERB = r"pass(?:ed|es|ing)?"
COUNT = r"\d[\d,]*"
CI_RESULT = re.compile(
    rf"\b(?:ci(?:\s+checks)?\s+(?:(?:has|is)\s+)?(?:{SUCCESS_VERB}|green|succeeded)"
    rf"|all\s+checks\s+(?:(?:are|have)\s+)?(?:green|{SUCCESS_VERB}|succeeded)"
    rf"|{COUNT}\s+tests?\s+{SUCCESS_VERB}|tests?\s+{SUCCESS_VERB}\b[\s:(]*{COUNT})\b",
    flags=re.IGNORECASE,
)


def conclusion_check(policy: Path) -> str:
    floor = tomllib.loads(policy.read_text(encoding="utf-8"))
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    Draft202012Validator(schema).validate(floor)
    return cast("str", floor["conclusion_check"])


def sections(body: str) -> dict[str, list[tuple[int, str]]]:
    """Collect H2 sections and keep line numbers for their content."""
    body = COMMENT.sub(lambda comment: "\n" * comment[0].count("\n"), body)
    found: dict[str, list[tuple[int, str]]] = {}
    lines: list[tuple[int, str]] = []
    fence = ""
    for number, line in enumerate(body.splitlines(), start=1):
        if marker := FENCE.match(line):
            if not fence:
                fence = marker[1]
            elif marker[1].startswith(fence) and not marker[2].strip():
                fence = ""
            continue
        if not fence and (heading := HEADING.match(line)):
            lines = found.setdefault(heading[2], []) if heading[1] == "##" else []
            continue
        lines.append((number, line))
    return found


def check_names_pattern(check_names: list[str]) -> re.Pattern[str]:
    names = "|".join(re.escape(name) for name in check_names)
    check = rf"(?:{names})"
    result = rf"(?:{SUCCESS_VERB}|green|success|succeeded|failed|pending|skipped)"
    return re.compile(
        rf"^{check}[.!]?$|\b(?:ci\s+)?check\s+{check}(?!\w)"
        rf"|(?<!\w){check}(?:\s*:\s*|\s+){result}\b"
        rf"|\b{result}\s+{check}(?!\w)",
        flags=re.IGNORECASE,
    )


def body_findings(body: str, required: list[str], check_names: list[str]) -> list[str]:
    found = sections(body)
    findings = [
        f"Missing required section {name!r}." for name in required if name not in found
    ]
    named_check = check_names_pattern(check_names)
    for number, line in found.get("Verification", []):
        plain = re.sub(r"[`*]", "", line).strip()
        plain = re.sub(r"^(?:[-+]|\d+[.)])\s+", "", plain)
        if CI_RESULT.search(plain) or named_check.search(plain):
            findings.append(
                f"Verification line {number} restates CI. "
                "List only checks CI does not show."
            )
    return findings


def head_sha(value: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        msg = "HEAD must be a full Git commit SHA."
        raise argparse.ArgumentTypeError(msg)
    return value


def main(argv: list[str] | None = None) -> int:
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", "."))
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--policy", type=Path, default=root / ".github/definition-of-done.toml"
    )
    common.add_argument(
        "--sections", type=Path, default=root / ".github/pull-request-sections.toml"
    )
    common.add_argument(
        "--check-name", action="append", default=[], help="A check name shown in CI"
    )

    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser(
        "body", parents=[common], help="Check the pull request body on stdin"
    )
    done = modes.add_parser(
        "done", parents=[common], help="Also check supplied review and CI evidence"
    )
    done.add_argument("--head", type=head_sha, required=True)
    done.add_argument("--reviewed-head")
    done.add_argument("--conclusion", nargs=3, metavar=("CHECK", "SHA", "RESULT"))
    args = parser.parse_args(argv)

    try:
        check = conclusion_check(args.policy)
        scheme = tomllib.loads(args.sections.read_text(encoding="utf-8"))
        required = [
            section["heading"] for section in scheme["section"] if section["required"]
        ]
    except (OSError, ValueError, ValidationError, KeyError, TypeError) as error:
        sys.stderr.write(f"pr_body: {error}\n")
        return 2

    findings = body_findings(sys.stdin.read(), required, [check, *args.check_name])
    if args.mode == "done":
        if args.reviewed_head != args.head:
            findings.append("The pull request head has no review evidence.")
        if args.conclusion != [check, args.head, "success"]:
            findings.append(f"Check {check!r} must succeed at the pull request head.")
    sys.stderr.writelines(f"pr_body: {finding}\n" for finding in findings)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
