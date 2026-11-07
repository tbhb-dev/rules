# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `commit_identity` target against a throwaway repository."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
repo="$TEST_TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
# The base commit's identity is not allowed, so a passing scenario also
# shows that the check keeps to the range.
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m base
base=$(git -C "$repo" rev-parse HEAD)
agent='tbhb.dev Agent <agent@tonyburns.net>'
# commit AUTHOR COMMITTER, each as `Name <email>`.
commit() {{
  local an=${{1% <*}} ae=${{1##*<}} cn=${{2% <*}} ce=${{2##*<}}
  GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=${{ae%>}} GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=${{ce%>}} \\
    git -C "$repo" commit -q --allow-empty -m change
}}
case {scenario} in
  allowed)
    commit "$agent" "$agent"
    commit 'Tony Burns <tony@tonyburns.net>' 'Tony Burns <tony@tonyburns.net>'
    commit 'tbhb-dev-renovate[bot] <289255489+tbhb-dev-renovate[bot]@users.noreply.github.com>' 'GitHub <noreply@github.com>'
    ;;
  empty) ;;
  noreply_author)
    commit "$agent" "$agent"
    commit 'tbhb-agent <334376894+tbhb-agent@users.noreply.github.com>' "$agent"
    ;;
  wrong_committer)
    commit "$agent" 'GitHub <noreply@github.com>'
    ;;
esac
BUILD_WORKSPACE_DIRECTORY="$repo" "$PWD/{subject}" "$base" HEAD
"""

def _commit_identity_scenario_test_impl(ctx):
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

commit_identity_scenario_test = rule(
    implementation = _commit_identity_scenario_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["allowed", "empty", "noreply_author", "wrong_committer"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
