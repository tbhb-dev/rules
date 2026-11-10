# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `gitleaks_history` target against a throwaway repository."""

load("@bazel_skylib//lib:shell.bzl", "shell")
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
  other_branch)
    # The checked-out branch is clean; another branch holds the key, as an
    # open pull request's ref does in a full-depth CI checkout.
    echo hello >"$repo/a.txt"
    commit clean
    git -C "$repo" checkout -q -b other
    printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR >"$repo/creds.txt"
    commit secret
    git -C "$repo" checkout -q -
    ;;
  range_secret|range_base_secret|range_config|range_empty)
    echo hello >"$repo/a.txt"
    commit base
    if [[ {scenario} == range_base_secret || {scenario} == range_config ]]; then
      printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR >"$repo/creds.txt"
      commit secret
      rm "$repo/creds.txt"
      commit removed
    fi
    git -C "$repo" branch -m base
    git -C "$repo" checkout -q -b pr
    case {scenario} in
      range_secret)
        printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR >"$repo/creds.txt"
        commit secret
        rm "$repo/creds.txt"
        commit removed
        ;;
      range_base_secret)
        echo change >>"$repo/a.txt"
        commit change
        ;;
      range_empty) commit empty ;;
      range_config)
        printf '[extend]\\nuseDefault = true\\n' >"$repo/.gitleaks.toml"
        commit config
        ;;
    esac
    git -C "$repo" checkout -q base
    git -C "$repo" merge -q --no-ff pr -m merge
    ;;
  range_linear)
    printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR >"$repo/creds.txt"
    commit secret
    rm "$repo/creds.txt"
    commit removed
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
status=0
BUILD_WORKSPACE_DIRECTORY="$repo" "$PWD/{subject}" {args} >"$TEST_TMPDIR/output" 2>&1 || status=$?
if [[ -n {expected_scan} ]] && ! grep -Fxq -- {expected_scan} "$TEST_TMPDIR/output"; then
  echo "expected scan announcement was missing" >&2
  exit 1
fi
cat "$TEST_TMPDIR/output"
exit "$status"
"""

def _gitleaks_history_scenario_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            args = " ".join([shell.quote(arg) for arg in ctx.attr.subject_args]),
            expected_scan = shell.quote(ctx.attr.expected_scan),
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
        "expected_scan": attr.string(doc = "Exact scan announcement required before accepting the result."),
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["clean", "corrupt", "no_commits", "no_content", "other_branch", "range_base_secret", "range_config", "range_empty", "range_linear", "range_secret", "secret"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
        "subject_args": attr.string_list(doc = "Arguments passed to the subject."),
    },
)
