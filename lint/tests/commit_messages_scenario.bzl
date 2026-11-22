# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `commit_messages` target against a throwaway repository."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
repo="$TEST_TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m base
base=$(git -C "$repo" rev-parse HEAD)
commit() {{ git -C "$repo" commit -q --allow-empty -m "$1"; }}
run() {{ BUILD_WORKSPACE_DIRECTORY="$repo" "$PWD/{subject}" "$base" HEAD; }}
case {scenario} in
  good)
    commit 'feat(lint): check each commit message'
    commit 'fix: handle an empty range'
    run
    ;;
  bad)
    commit 'feat(lint): check each commit message'
    commit 'fixup! feat: x'
    commit 'address review'
    status=0
    out=$(run 2>&1) || status=$?
    [[ "$status" == 1 ]] || {{ echo "status $status, expected 1: $out" >&2; exit 1; }}
    [[ "$out" == *'fixup!, squash! and amend! subjects must be reworded'* ]] || {{ echo "$out" >&2; exit 1; }}
    [[ "$out" == *'subject is too generic; say what changed'* ]] || {{ echo "$out" >&2; exit 1; }}
    [[ "$out" == *'commit_messages: 2 of 3 commits failed.'* ]] || {{ echo "$out" >&2; exit 1; }}
    ;;
  merge_skipped)
    commit 'feat(lint): check each commit message'
    git -C "$repo" checkout -q -b side
    commit 'feat(lint): side work'
    git -C "$repo" checkout -q -
    commit 'fix: main work'
    git -C "$repo" merge -q --no-ff -m 'Merge pull request #1 from side' side
    out=$(run 2>&1)
    [[ "$out" == 'commit_messages: 3 commits checked' ]] || {{ echo "$out" >&2; exit 1; }}
    ;;
esac
"""

def _impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            git_dir = path_dir(ctx.attr.git),
            scenario = ctx.attr.scenario,
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject, ctx.executable.git])
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, driver, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

commit_messages_scenario_test = rule(
    implementation = _impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["good", "bad", "merge_skipped"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
