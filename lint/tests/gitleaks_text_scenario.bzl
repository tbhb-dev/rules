# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `gitleaks_text` target on text piped in, in a throwaway workspace."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
ws="$TEST_TMPDIR/ws"
mkdir -p "$ws"
case {scenario} in
  clean | secret | secret_ids | secret_awk_fails | secret_rm_fails) printf '[extend]\\nuseDefault = true\\n' >"$ws/.gitleaks.toml" ;;
  clean_no_config) ;;
esac
case {scenario} in
  clean | clean_no_config) text='fix(ci): a title\\n\\nA body with no secret in it.\\n' ;;
  # Assembled here, so no key sits in this repository's history.
  secret) text="aws_access_key_id = AKIA""Z7Q3XK2M5TNB4VWR\\n" ;;
  secret_ids) text="A title\\n\\nThe deploy notes say:\\naws_access_key_id = AKIA""Z7Q3XK2M5TNB4VWR\\nand nothing else.\\n" ;;
esac
if [[ {scenario} == secret_awk_fails ]]; then
  # An awk that fails must not replace the scanner's exit status.
  mkdir -p "$ws/stubs"
  printf '#!/bin/sh\\nfor last; do :; done\\ncp "$last" "%s/report.json"\\nexit 2\\n' "$ws" >"$ws/stubs/awk"
  chmod +x "$ws/stubs/awk"
  status=0
  printf "A title\\n\\naws_access_key_id = AKIA""Z7Q3XK2M5TNB4VWR\\n" | PATH="$ws/stubs:$PATH" BUILD_WORKSPACE_DIRECTORY="$ws" "$PWD/{subject}" >"$ws/out.txt" 2>"$ws/err.txt" || status=$?
  cat "$ws/out.txt" "$ws/err.txt"
  if ((status != 1)); then
    echo "FAIL: exit status $status, expected the scanner's 1" >&2
    exit 1
  fi
  # The stub copied the script's own report, the last awk argument: it must
  # hold a finding with the secret redacted.
  if ! grep -q RuleID "$ws/report.json"; then
    echo "FAIL: no finding in the report" >&2
    exit 1
  fi
  if grep -Fq "$(printf '%s%s' AKIA Z7Q3XK2M5TNB4VWR)" "$ws/report.json"; then
    echo "FAIL: the report holds the secret in the clear" >&2
    exit 1
  fi
  exit 0
fi
if [[ {scenario} == secret_rm_fails ]]; then
  # A failing cleanup (status 5) must not replace the scanner's exit status 1.
  mkdir -p "$ws/stubs"
  printf '#!/bin/sh\\nfor last; do :; done\\ncp "$last" "%s/report.json"\\nexit 5\\n' "$ws" >"$ws/stubs/rm"
  chmod +x "$ws/stubs/rm"
  status=0
  printf "A title\\n\\naws_access_key_id = AKIA""Z7Q3XK2M5TNB4VWR\\n" | PATH="$ws/stubs:$PATH" BUILD_WORKSPACE_DIRECTORY="$ws" "$PWD/{subject}" >"$ws/out.txt" 2>"$ws/err.txt" || status=$?
  cat "$ws/out.txt" "$ws/err.txt"
  if ((status != 1)); then
    echo "FAIL: exit status $status, expected the scanner's 1" >&2
    exit 1
  fi
  # The stub copied the script's own report, the last rm argument: it must
  # hold a finding with the secret redacted.
  if ! grep -q RuleID "$ws/report.json"; then
    echo "FAIL: no finding in the report" >&2
    exit 1
  fi
  if grep -Fq "$(printf '%s%s' AKIA Z7Q3XK2M5TNB4VWR)" "$ws/report.json"; then
    echo "FAIL: the report holds the secret in the clear" >&2
    exit 1
  fi
  exit 0
fi
if [[ {scenario} == secret_ids ]]; then
  status=0
  printf "$text" | BUILD_WORKSPACE_DIRECTORY="$ws" "$PWD/{subject}" >"$ws/out.txt" 2>"$ws/err.txt" || status=$?
  cat "$ws/out.txt" "$ws/err.txt"
  if ((status != 1)); then
    echo "FAIL: exit status $status, expected 1" >&2
    exit 1
  fi
  if ! grep -Fxq 'gitleaks_text: rule=aws-access-token line=4' "$ws/err.txt"; then
    echo "FAIL: stderr does not name the rule and line" >&2
    exit 1
  fi
  if grep -Fq "$(printf '%s%s' AKIA Z7Q3XK2M5TNB4VWR)" "$ws/out.txt" "$ws/err.txt"; then
    echo "FAIL: planted secret leaked into the output" >&2
    exit 1
  fi
  exit 0
fi
printf "$text" | BUILD_WORKSPACE_DIRECTORY="$ws" "$PWD/{subject}"
"""

def _gitleaks_text_scenario_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            scenario = ctx.attr.scenario,
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject])
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, driver, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_text_scenario_test = rule(
    implementation = _gitleaks_text_scenario_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "scenario": attr.string(mandatory = True, values = ["clean", "clean_no_config", "secret", "secret_ids", "secret_awk_fails", "secret_rm_fails"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
