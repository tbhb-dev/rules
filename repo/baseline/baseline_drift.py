# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- The Bazel launcher also runs this module by path.

"""Check and sync a consumer's bytes-mode baseline files."""

import argparse
import json
import re
import stat
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from tempfile import NamedTemporaryFile
from typing import NotRequired, TypedDict, cast

from jsonschema import Draft202012Validator, ValidationError

BASELINE = Path(__file__).parent
TEMPLATE = re.compile(rb"(?<!\$){{([a-z][a-z0-9_]*)}}")
RENOVATE_PIN = re.compile(
    rb"(?m)^ *uses: +tbhb-dev/renovate-config/\.github/workflows/"
    rb"[a-z0-9-]+\.yaml@([a-fA-F0-9]{40})(?=[ \t\r\n]|$)"
)

type Json = dict[str, Json] | list[Json] | str | int | float | bool | None


class Entry(TypedDict):
    path: str
    source: str
    mode: str
    visibility: NotRequired[str]
    kinds: NotRequired[list[str]]
    template: NotRequired[bool]


class Manifest(TypedDict):
    file: list[Entry]
    kinds: list[str]
    never_write: list[str]
    placeholders: list[str]


class ExceptionEntry(TypedDict):
    check: str
    path: str
    reason: str


class Declaration(TypedDict):
    kind: str
    private: bool
    exception: NotRequired[list[ExceptionEntry]]


class DeclarationError(ValueError):
    """The consumer declaration or an exception needs correction."""


class TemplateInputsError(ValueError):
    """The consumer does not supply all the values a template needs."""


@dataclass(frozen=True)
class Difference:
    path: str
    status: str
    source: Path
    expected: bytes | None
    detail: str = ""


def load_toml(path: Path) -> dict[str, object]:
    with path.open("rb") as stream:
        return tomllib.load(stream)


def validator(path: Path) -> Draft202012Validator:
    return Draft202012Validator(json.loads(path.read_bytes()))


def load_declaration(repo: Path, baseline: Path) -> Declaration:
    schema = validator(baseline / "repo.schema.json")
    path = repo / ".tbhb-repo.toml"
    try:
        data = load_toml(path)
        schema.validate(data)
    except (FileNotFoundError, ValueError, ValidationError) as error:
        detail = error.message if isinstance(error, ValidationError) else str(error)
        msg = f"{path.name}: {detail}"
        raise DeclarationError(msg) from error
    return cast("Declaration", data)


def c2_exceptions(declaration: Declaration) -> dict[str, str]:
    exceptions: dict[str, str] = {}
    for entry in declaration.get("exception", []):
        if entry["check"] != "C2":
            continue
        path = entry["path"]
        if path in exceptions:
            msg = f".tbhb-repo.toml: duplicate C2 exception for {path}"
            raise DeclarationError(msg)
        exceptions[path] = entry["reason"]
    return exceptions


def selected_entries(manifest: Manifest, declaration: Declaration) -> list[Entry]:
    visibility = "private" if declaration["private"] else "public"
    return [
        entry
        for entry in manifest["file"]
        if entry["mode"] == "bytes"
        and entry.get("visibility", "all") in ("all", visibility)
        and declaration["kind"] in entry.get("kinds", manifest["kinds"])
    ]


def mcp_values(content: bytes) -> dict[str, str]:
    try:
        document = cast("Json", json.loads(content))
    except ValueError, UnicodeError:
        return {}
    match document:
        case {"mcpServers": {**servers}} if len(servers) == 1:
            [(server, config)] = servers.items()
        case _:
            return {}
    server_config: Json = config
    match server_config:
        case {"args": ["run", str(module), "mcp"], "env": {**env}}:
            match list(env.items()):
                case [(str(endpoint_env), str(endpoint)), (str(token_env), str(token))]:
                    # Keep both existing name/value pairs in their original order.
                    return {
                        "mcp_server": server,
                        "mcp_module": module,
                        "mcp_endpoint_env": endpoint_env,
                        "mcp_endpoint": endpoint,
                        "mcp_token_file_env": token_env,
                        "mcp_token_file": token,
                    }
                case _:
                    return {}
        case _:
            return {}


def render(path: str, template: bytes, current: bytes, values: dict[str, str]) -> bytes:
    tokens = {token.decode() for token in TEMPLATE.findall(template)}
    if tokens <= values.keys():
        inputs = values
    elif path == ".mcp.json":
        inputs = mcp_values(current) | values
    else:
        pins = set(RENOVATE_PIN.findall(current))
        inferred = (
            {"renovate_config_sha": pins.pop().decode()} if len(pins) == 1 else {}
        )
        inputs = inferred | values
    missing = tokens - inputs.keys()
    if missing:
        msg = f"template values needed for {', '.join(sorted(missing))}"
        raise TemplateInputsError(msg)
    if "renovate_config_sha" in tokens and not re.fullmatch(
        r"[a-fA-F0-9]{40}", inputs["renovate_config_sha"]
    ):
        msg = "renovate_config_sha needs a 40-digit hexadecimal commit"
        raise TemplateInputsError(msg)
    if path.endswith(".json"):
        inputs = {
            key: json.dumps(inputs[key], ensure_ascii=False)[1:-1] for key in tokens
        }

    def substitute(match: re.Match[bytes]) -> bytes:
        return inputs[match[1].decode()].encode()

    return TEMPLATE.sub(substitute, template)


def difference(
    repo: Path, baseline: Path, entry: Entry, values: dict[str, str]
) -> Difference | None:
    path = entry["path"]
    source = baseline / entry["source"]
    expected = source.read_bytes()
    try:
        current = (repo / path).read_bytes()
    except FileNotFoundError:
        current = None
    status = "missing" if current is None else "differs"
    if entry.get("template", False):
        try:
            expected = render(path, expected, current or b"", values)
        except TemplateInputsError as error:
            return Difference(path, status, source, None, str(error))
    if current == expected:
        return None
    return Difference(path, status, source, expected)


def pending_changes(
    repo: Path, baseline: Path, manifest: Manifest, values: dict[str, str]
) -> list[Difference]:
    declaration = load_declaration(repo, baseline)
    exceptions = c2_exceptions(declaration)
    changes = {
        diff.path: diff
        for entry in selected_entries(manifest, declaration)
        if (diff := difference(repo, baseline, entry, values)) is not None
    }
    stale = exceptions.keys() - changes.keys()
    if stale:
        msg = f".tbhb-repo.toml: stale C2 exceptions for {', '.join(sorted(stale))}"
        raise DeclarationError(msg)
    for path, reason in exceptions.items():
        sys.stdout.write(f"C2 exception for {path}: {reason}\n")
        del changes[path]
    return list(changes.values())


def write_file(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.close()
            temporary.chmod(stat.S_IMODE(mode))
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def plan_write(
    repo: Path, diff: Difference, never_write: list[str]
) -> tuple[Path, bytes, int, str]:
    path = repo / diff.path
    if diff.expected is None:
        msg = f"{diff.path}: {diff.detail}"
        raise ValueError(msg)
    if path.resolve() != path or not path.is_relative_to(repo):
        msg = f"{diff.path}: sync needs a regular path inside the consumer root"
        raise ValueError(msg)
    if any(PurePosixPath(diff.path).full_match(pattern) for pattern in never_write):
        msg = f"{diff.path}: protected by never_write"
        raise ValueError(msg)
    missing = diff.status == "missing"
    mode = (diff.source if missing else path).stat().st_mode
    return path, diff.expected, mode, "create" if missing else "update"


def sync_changes(
    repo: Path, changes: list[Difference], never_write: list[str], *, dry_run: bool
) -> int:
    writes = [plan_write(repo, diff, never_write) for diff in changes]
    prefix = "Would " if dry_run else ""
    for path, content, mode, action in writes:
        if not dry_run:
            write_file(path, content, mode)
        sys.stdout.write(f"{prefix}{action} {path.relative_to(repo).as_posix()}\n")
    return 0


def main(argv: list[str] | None = None, *, baseline: Path = BASELINE) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("repo", type=Path)
    check.add_argument("--mode", choices=["warn", "required"], required=True)
    sync = commands.add_parser("sync")
    sync.add_argument("repo", type=Path)
    sync.add_argument("--dry-run", action="store_true")
    sync.add_argument(
        "--value",
        nargs=2,
        metavar=("NAME", "VALUE"),
        action="append",
        default=[],
        help="Supply a value for a baseline template",
    )
    args = parser.parse_args(argv)
    try:
        data = load_toml(baseline / "manifest.toml")
        validator(baseline / "manifest.schema.json").validate(data)
        manifest = cast("Manifest", data)
        repo: Path = args.repo.resolve()
        values: dict[str, str] = dict(args.value) if args.command == "sync" else {}
        if values.keys() - set(manifest["placeholders"]):
            sys.stderr.write("C2 error: unknown baseline template value\n")
            return 2
        changes = pending_changes(repo, baseline, manifest, values)
        if args.command == "sync":
            return sync_changes(
                repo, changes, manifest["never_write"], dry_run=args.dry_run
            )
    except DeclarationError as error:
        sys.stderr.write(f"C2 error: {error}\n")
        return 1
    except (OSError, ValueError, ValidationError) as error:
        sys.stderr.write(f"C2 error: {error}\n")
        return 2
    warns: bool = args.mode == "warn"
    for diff in changes:
        level = "warning" if warns else "error"
        detail = f" ({diff.detail})" if diff.detail else ""
        sys.stdout.write(f"C2 {level}: {diff.path} {diff.status}{detail}\n")
    return 1 if changes and not warns else 0


if __name__ == "__main__":
    sys.exit(main())
