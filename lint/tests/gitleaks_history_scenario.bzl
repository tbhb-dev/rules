# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `gitleaks_history` target against a throwaway repository."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
repo="$TEST_TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
commit() {{
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m "$1"
}}
case {scenario} in
  clean)
    echo hello >"$repo/a.txt"
    commit clean
    ;;
  secret)
    # Assembled here, so no key sits in this repository's history.
    printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR >"$repo/creds.txt"
    commit secret
    ;;
  no_commits) ;;
  no_content) commit empty ;;
  corrupt)
    echo hello >"$repo/a.txt"
    commit corrupt
    blob=$(git -C "$repo" rev-parse HEAD:a.txt)
    rm -f "$repo/.git/objects/${{blob:0:2}}/${{blob:2}}"
    ;;
esac
BUILD_WORKSPACE_DIRECTORY="$repo" "$PWD/{subject}"
"""

def _gitleaks_history_scenario_test_impl(ctx):
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

gitleaks_history_scenario_test = rule(
    implementation = _gitleaks_history_scenario_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["clean", "corrupt", "no_commits", "no_content", "secret"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
