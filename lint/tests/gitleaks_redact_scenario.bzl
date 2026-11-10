# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Checks that real gitleaks targets report findings without printing secrets."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

# Build and test actions assemble made-up credentials; no complete token is
# stored in this repository. The tree subject scans the generated file.
GITLEAKS_REDACT_FIXTURE = """printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR
printf 'github_token = %s%s\\n' ghp_ aB3dE6gH9jK2mN5pQ8sT1vW4yZ7cF0hJ3kL6
"""

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
subject="$PWD/{subject}"
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
work="$TEST_TMPDIR/work"
mkdir -p "$work"
(
  {fixture}
) >"$work/creds.txt"
status=0
case {scenario} in
  history)
    git -C "$work" init -q
    git -C "$work" config user.email test@example.invalid
    git -C "$work" config user.name test
    git -C "$work" add creds.txt
    git -C "$work" commit -qm secret
    commit=$(git -C "$work" rev-parse HEAD)
    # Only history holds the tokens when the scan runs.
    git -C "$work" rm -q creds.txt
    git -C "$work" commit -qm removed
    BUILD_WORKSPACE_DIRECTORY="$work" "$subject" --log-opts=HEAD >"$work/out.txt" 2>"$work/stderr.txt" || status=$?
    ;;
  text)
    # The CI target reads PR text on stdin. Verbose adds finding metadata.
    BUILD_WORKSPACE_DIRECTORY="$work" "$subject" --verbose <"$work/creds.txt" >"$work/out.txt" 2>"$work/stderr.txt" || status=$?
    ;;
  tree)
    "$subject" >"$work/out.txt" 2>"$work/stderr.txt" || status=$?
    ;;
esac
cd "$work"
# Check stdout and stderr separately, including text hidden by ANSI colors.
for output in out.txt stderr.txt; do
  sed -E $'s/\\033\\\\[[0-?]*[ -/]*[@-~]//g' "$output" >"$output.clean"
  for token in "$(printf '%s%s' AKIA Z7Q3XK2M5TNB4VWR)" "$(printf '%s%s' ghp_ aB3dE6gH9jK2mN5pQ8sT1vW4yZ7cF0hJ3kL6)"; do
    if grep -Fq -- "$token" "$output" "$output.clean"; then
      echo "FAIL: {scenario}: planted secret leaked in $output (raw or ANSI-stripped)" >&2
      exit 1
    fi
  done
done
cat out.txt stderr.txt
if ((status != 1)); then
  echo "FAIL: {scenario}: exit status $status, expected 1" >&2
  exit 1
fi
cat out.txt.clean stderr.txt.clean >combined.txt
patterns=('RuleID: +aws-access-token' 'RuleID: +github-pat' REDACTED)
# Gitleaks stdin findings have no File or Line fields, even with --verbose.
if [[ {scenario} != text ]]; then
  patterns+=('File: +[^[:space:]]+' 'Line: +1' 'Line: +2')
fi
for pattern in "${{patterns[@]}}"; do
  if ! grep -Eq -- "$pattern" combined.txt; then
    echo "FAIL: {scenario}: output does not match: $pattern" >&2
    exit 1
  fi
done
if [[ {scenario} == history ]] && ! grep -Eq "Commit: +$commit" combined.txt; then
  echo "FAIL: history: output does not name the commit" >&2
  exit 1
fi
"""

def _gitleaks_redact_scenario_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            fixture = GITLEAKS_REDACT_FIXTURE,
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

gitleaks_redact_scenario_test = rule(
    implementation = _gitleaks_redact_scenario_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["history", "text", "tree"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
