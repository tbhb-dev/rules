# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Hold reasons are stable decision codes.
# Mutation pragmas on casts omit static type changes. Data lookups stay mutable.
# ruff: noqa: EM101
# cspell:ignore textconv

import json
import os
import re
import subprocess  # nosec B404 - Uses argument vectors with Git and GitHub CLI only.
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory
from typing import TYPE_CHECKING, cast
from urllib.parse import urlencode

if TYPE_CHECKING:
    from collections.abc import Mapping

PAGINATE = ("--paginate", "--slurp")
APP = "tbhb-dev-auto-reviews"
BOT = f"{APP}[bot]"
ARTIFACT = "tier0-decision.json"


type Record = dict[str, object]


class HoldError(Exception):
    pass


def command(*args: str, env: Mapping[str, str] | None = None) -> str:
    # Fixed executables and argument vectors, without shell expansion.
    return subprocess.check_output(  # nosec B603  # noqa: S603
        args, encoding="utf-8", stderr=subprocess.PIPE, env=env
    )


def sha(value: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise HoldError("invalid-sha")
    return value


def api(
    repo: str, path: str, *flags: str, auth_env: str | None = None, **query: str
) -> object:
    endpoint = f"repos/{repo}/{path}?{urlencode(query)}"
    env = None
    if auth_env is not None:
        token = os.environ.get(auth_env)
        if not token:
            raise HoldError("missing-actions-token")
        env = os.environ | {"GH_TOKEN": token}
    response: object = json.loads(command("gh", "api", endpoint, *flags, env=env))
    return response


def context_pass(repo: str, head: str, spec: str) -> bool:
    name, _, workflow = (part.strip() for part in spec.rpartition(":"))
    if not (name and re.fullmatch(r"[1-9][0-9]*", workflow)):
        return False
    response = api(
        repo,
        f"actions/workflows/{workflow}/runs",
        auth_env="ACTIONS_TOKEN",
        head_sha=head,
        per_page="1",
    )
    payload = cast("dict[str, list[Record]]", response)  # pragma: no mutate
    runs = payload["workflow_runs"]
    if not runs:
        return False
    run = runs[0]
    if (run["workflow_id"], run["head_sha"], run["conclusion"]) != (
        int(workflow),
        head,
        "success",
    ):
        return False
    suite = run["check_suite_id"]
    response = api(repo, f"check-suites/{suite}/check-runs", *PAGINATE, check_name=name)
    pages = cast("list[dict[str, list[Record]]]", response)  # pragma: no mutate
    conclusions = [
        check["conclusion"]
        for page in pages
        for check in page["check_runs"]
        if record(check["check_suite"])["id"] == suite
        and (check["name"], check["head_sha"]) == (name, head)
    ]
    return conclusions == ["success"]


def contexts_pass(repo: str, head: str, config: str) -> bool:
    return bool(config.strip()) and all(
        context_pass(repo, head, spec) for spec in config.splitlines()
    )


def changed_paths(repo: str, base: str, head: str) -> tuple[list[str], bool]:
    # A bare repository never checks out or applies the PR's attributes.
    with TemporaryDirectory() as directory:
        git = ("git", "-C", directory)
        command(*git, "init", "--bare", "--quiet")
        url = f"https://github.com/{repo}.git"
        helper = "credential.helper=!gh auth git-credential"
        credentials = ("-c", "credential.helper=", "-c", helper)
        command(*git, *credentials, "fetch", "--quiet", "--no-tags", url, base, head)
        flags = "--raw --numstat -z --no-renames --no-ext-diff --no-textconv"
        flags += " --ignore-submodules=none --merge-base"
        diff = command(*git, "diff", *flags.split(), base, head, "--")
    records = iter(diff.split("\0")[:-1])
    paths = []
    regular_text = True
    for record in records:
        if record.startswith(":"):
            old_mode, new_mode, *_ = record[1:].split()
            regular_text &= {old_mode, new_mode} <= {"000000", "100644"}
            next(records)  # The path is also in the numstat section.
        else:
            added, removed, path = record.split("\t", 2)
            regular_text &= added.isdecimal() and removed.isdecimal()
            paths.append(path)
    return paths, regular_text


def matches(path: str, patterns: str) -> bool:
    return any(
        PurePosixPath(path).full_match(line.strip(), case_sensitive=False)
        for line in patterns.splitlines()
        if line.strip()
    )


def record(value: object) -> Record:
    return cast("Record", value)  # pragma: no mutate


def find_pull(repo: str, run: Record, head: str) -> object:
    full_name = record(run["head_repository"])["full_name"]
    source = cast("str", full_name)  # pragma: no mutate
    branch = run["head_branch"]
    source_head = f"{source.split('/')[0]}:{branch}"
    pulls = api(repo, "pulls", *PAGINATE, state="open", head=source_head)
    pages = cast("list[list[Record]]", pulls)  # pragma: no mutate
    candidates = [
        pr["number"]
        for page in pages
        for pr in page
        if (ref := record(pr["head"]))["sha"] == head
        and ref["ref"] == branch
        and record(ref["repo"])["full_name"] == source
    ]
    if len(candidates) != 1:
        raise HoldError("no-unique-open-pr")
    return candidates[0]


def evaluate(
    repo: str, run: Record, env: Mapping[str, str], result: Record
) -> tuple[str, str]:
    run_head = run["head_sha"]
    head_sha = cast("str", run_head)  # pragma: no mutate
    head = result["head_sha"] = sha(head_sha)
    if run["conclusion"] != "success":
        raise HoldError("ci-unsuccessful")
    if env["APP_SLUG"] != APP:
        raise HoldError("unexpected-approver")
    if any(is_approver(actor) for actor in (run["actor"], run["triggering_actor"])):
        raise HoldError("approver-is-pusher")
    result["pr"] = find_pull(repo, run, head)
    endpoint = f"pulls/{result['pr']}"
    pr = record(api(repo, endpoint))
    pr_base = record(pr["base"])
    raw_base = pr_base["sha"]
    base_sha = cast("str", raw_base)  # pragma: no mutate
    base = sha(base_sha)
    require_current(pr, head, base)
    commit = record(api(repo, f"commits/{head}"))
    if any(is_approver(user) for user in (commit["author"], commit["committer"])):
        raise HoldError("approver-is-committer")
    require_no_app_push(repo, f"refs/heads/{run['head_branch']}")
    if not contexts_pass(repo, head, env["CHECK_WORKFLOWS"]):
        raise HoldError("checks-unsuccessful")
    paths, regular_text = changed_paths(repo, base, head)
    result["files"] = len(paths)
    if not 0 < len(paths) <= int(env["MAX_FILES"]):
        raise HoldError("file-count")
    if not regular_text:
        raise HoldError("unsupported-file")
    if any(not tier0_path(path, env) for path in paths):
        raise HoldError("path-outside-tier0")
    if (
        any(matches(path, env["DESIGN_PATHS"]) for path in paths)
        and env["DESIGN_GO_SHA"] != head
    ):
        raise HoldError("design-needs-go")
    return endpoint, base


def require_no_app_push(repo: str, ref: str) -> None:
    activity = api(repo, "activity", *PAGINATE, ref=ref, actor=BOT)
    pages = cast("list[list[Record]]", activity)  # pragma: no mutate
    for page in pages:
        if any(entry["activity_type"] != "branch_deletion" for entry in page):
            raise HoldError("approver-is-pusher")


def tier0_path(path: str, env: Mapping[str, str]) -> bool:
    return (
        not path.startswith("/")
        and "\\" not in path
        and not {".", ".."}.intersection(path.split("/"))
        and matches(path, env["TIER0_PATHS"])
        and not matches(path, env["DENY_PATHS"])
    )


def is_approver(user: object) -> bool:
    if user is None:
        return False
    login = record(user)["login"]
    name = cast("str", login)  # pragma: no mutate
    return name.casefold() == BOT


def require_current(pr: Record, head: str, base: str) -> None:
    pr_head, pr_base = record(pr["head"]), record(pr["base"])
    if (pr["state"], pr_head["sha"], pr_base["sha"]) != ("open", head, base):
        raise HoldError("pr-changed")
    raw_labels = pr["labels"]
    labels = cast("list[dict[str, str]]", raw_labels)  # pragma: no mutate
    if any(label["name"].casefold() == "no-auto-approval" for label in labels):
        raise HoldError("opted-out")
    if (
        pr["draft"]
        or record(pr_head["repo"])["full_name"] != record(pr_base["repo"])["full_name"]
    ):
        raise HoldError("not-eligible")
    if is_approver(pr["user"]):
        raise HoldError("approver-is-author")


def decide(run: Record, env: Mapping[str, str]) -> Record:
    result: Record = {"decision": "hold", "pr": None, "head_sha": "", "files": 0}
    repo = env["GITHUB_REPOSITORY"]
    try:
        endpoint, base = evaluate(repo, run, env, result)
        if env["MODE"] == "enforce":
            head_sha = result["head_sha"]
            head = cast("str", head_sha)  # pragma: no mutate
            require_current(record(api(repo, endpoint)), head, base)
            fields = ("-f", f"commit_id={head}", "-f", "event=APPROVE")
            api(repo, f"{endpoint}/reviews", "--method", "POST", *fields)
        elif env["MODE"] != "evaluate":
            return result | {"reason": "invalid-mode"}
        result.update(decision="approve", reason="tier0")
    except HoldError as error:
        result["reason"] = str(error)
    except KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError:
        result["reason"] = "evidence-or-command-failed"
    return result


def main() -> None:
    event_path = Path(os.environ["GITHUB_EVENT_PATH"])
    event = record(json.loads(event_path.read_text(encoding="utf-8")))
    result = decide(record(event["workflow_run"]), os.environ)
    artifact = json.dumps(result)
    Path(ARTIFACT).write_text(f"{artifact}\n", encoding="utf-8")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.writelines(
            f"{key}={result[key]}\n" for key in ("decision", "reason", "head_sha")
        )
    print(artifact)  # noqa: T201


if __name__ == "__main__":
    main()
