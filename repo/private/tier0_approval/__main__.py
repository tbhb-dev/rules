# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Hold reasons are stable decision codes.
# ruff: noqa: EM101
# cspell:ignore textconv

import json
import os
import re
import subprocess
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory
from urllib.parse import urlencode

PAGINATE = ("--paginate", "--slurp")


class HoldError(Exception):
    pass


def command(*args: str) -> str:
    return subprocess.check_output(args, encoding="utf-8", stderr=subprocess.PIPE)  # noqa: S603


def sha(value: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise HoldError("invalid-sha")
    return value


def api(repo: str, path: str, *flags: str, **query: str) -> object:
    endpoint = f"repos/{repo}/{path}?{urlencode(query)}"
    return json.loads(command("gh", "api", endpoint, *flags))


def context_pass(repo: str, head: str, spec: str) -> bool:
    name, _, workflow = spec.strip().rpartition(":")
    if not (name.strip() and re.fullmatch(r"[1-9][0-9]*", workflow.strip())):
        return False
    endpoint = f"actions/workflows/{workflow.strip()}/runs"
    runs = api(repo, endpoint, head_sha=head, per_page="1")["workflow_runs"]
    if not runs or runs[0]["head_sha"] != head or runs[0]["status"] != "completed":
        return False
    endpoint = f"commits/{head}/check-runs"
    checks = api(repo, endpoint, *PAGINATE, check_name=name.strip(), per_page="100")
    conclusions = [
        check["conclusion"]
        for page in checks
        for check in page["check_runs"]
        if check["check_suite"]["id"] == runs[0]["check_suite_id"]
        and check["name"] == name.strip()
        and check["head_sha"] == head
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
        diff = command(
            *git,
            "diff",
            *flags.split(),
            "--ignore-submodules=none",
            "--merge-base",
            base,
            head,
            "--",
        )
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
        PurePosixPath(path).full_match(pattern.strip())
        for pattern in patterns.splitlines()
        if pattern.strip()
    )


def evaluate(repo: str, run: dict, env: dict, result: dict) -> tuple[str, str]:
    head = result["head_sha"] = sha(run["head_sha"])
    if run["conclusion"] != "success":
        raise HoldError("ci-unsuccessful")
    source = run["head_repository"]["full_name"]
    branch = run["head_branch"]
    source_head = f"{source.split('/')[0]}:{branch}"
    pulls = api(
        repo, "pulls", *PAGINATE, state="open", head=source_head, per_page="100"
    )
    candidates = [
        pr["number"]
        for page in pulls
        for pr in page
        if pr["head"]["sha"] == head
        and pr["head"]["ref"] == branch
        and pr["head"]["repo"]["full_name"] == source
    ]
    if len(candidates) != 1:
        raise HoldError("no-unique-open-pr")
    result["pr"] = candidates[0]
    endpoint = f"pulls/{result['pr']}"
    pr = api(repo, endpoint)
    base = sha(pr["base"]["sha"])
    require_current(pr, head, base, env["APP_SLUG"])
    if not contexts_pass(repo, head, env["CHECK_WORKFLOWS"]):
        raise HoldError("checks-unsuccessful")
    paths, regular_text = changed_paths(repo, base, head)
    result["files"] = len(paths)
    if not 0 < len(paths) <= int(env["MAX_FILES"]):
        raise HoldError("file-count")
    if not regular_text:
        raise HoldError("unsupported-file")
    if any(
        not matches(path, env["TIER0_PATHS"]) or matches(path, env["DENY_PATHS"])
        for path in paths
    ):
        raise HoldError("path-outside-tier0")
    if (
        any(matches(path, env["DESIGN_PATHS"]) for path in paths)
        and env["DESIGN_GO_SHA"] != head
    ):
        raise HoldError("design-needs-go")
    return endpoint, base


def require_current(pr: dict, head: str, base: str, app_slug: str) -> None:
    if pr["state"] != "open" or pr["head"]["sha"] != head or pr["base"]["sha"] != base:
        raise HoldError("pr-changed")
    labels = {label["name"].casefold() for label in pr["labels"]}
    if "no-auto-approval" in labels:
        raise HoldError("opted-out")
    if not app_slug or pr["user"]["login"].casefold() == f"{app_slug.casefold()}[bot]":
        raise HoldError("approver-is-author")


def decide(run: dict, env: dict) -> dict:
    result = {"decision": "hold", "reason": "", "pr": None, "head_sha": "", "files": 0}
    repo = env["GITHUB_REPOSITORY"]
    try:
        endpoint, base = evaluate(repo, run, env, result)
        head = result["head_sha"]
        match env["MODE"]:
            case "evaluate":
                result.update(decision="approve", reason="tier0")
            case "enforce":
                require_current(api(repo, endpoint), head, base, env["APP_SLUG"])
                fields = ("-f", f"commit_id={head}", "-f", "event=APPROVE")
                api(repo, f"{endpoint}/reviews", "--method", "POST", *fields)
                result.update(decision="approve", reason="merge-failed")
                # gh automatically uses auto-merge for a queue-enabled base.
                merge = ("--repo", repo, "--squash", "--match-head-commit", head)
                command("gh", "pr", "merge", str(result["pr"]), *merge)
                result["reason"] = "merge-requested"
            case _:
                result["reason"] = "invalid-mode"
    except HoldError as error:
        result["reason"] = str(error)
    except KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError:
        result["reason"] = result["reason"] or "evidence-or-command-failed"
    return result


def main() -> None:
    event_path = Path(os.environ["GITHUB_EVENT_PATH"])
    event = json.loads(event_path.read_text(encoding="utf-8"))
    result = decide(event["workflow_run"], os.environ)
    artifact = json.dumps(result)
    Path("tier0-decision.json").write_text(f"{artifact}\n", encoding="utf-8")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.writelines(
            f"{key}={result[key]}\n" for key in ("decision", "reason", "head_sha")
        )
    print(artifact)  # noqa: T201


if __name__ == "__main__":
    main()
