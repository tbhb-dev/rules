# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `gitleaks_tool` target against a throwaway tree and checks the result."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
tool="$PWD/{subject}"
work="$TEST_TMPDIR/work"
mkdir -p "$work"
cd "$work"
printf '[extend]\\nuseDefault = true\\n' >.gitleaks.toml
private='[extend]
path = ".gitleaks.toml"

[[rules]]
id = "tbhb-private-canary"
description = "Proves the private config loaded"
regex = '"'''tbhb-private-canary-[0-9a-f]{{8}}'''"'

[[rules]]
id = "tbhb-private-word"
description = "A name only the private config knows"
regex = '"'''lighthouse-[0-9]{{4}}'''"'
'
config=.gitleaks.toml
echo hello >a.txt
case {scenario} in
  unset) unset GITLEAKS_CONFIG_TOML ;;
  empty) export GITLEAKS_CONFIG_TOML= ;;
  no_canary) export GITLEAKS_CONFIG_TOML='[extend]
path = ".gitleaks.toml"' ;;
  other_config)
    export GITLEAKS_CONFIG_TOML="$private"
    config=other.toml
    ;;
  no_committed)
    export GITLEAKS_CONFIG_TOML="$private"
    rm .gitleaks.toml
    ;;
  clean) export GITLEAKS_CONFIG_TOML="$private" ;;
  findings)
    export GITLEAKS_CONFIG_TOML="$private"
    # Assembled here, so no key or name sits in this repository's files.
    printf 'aws_access_key_id = %s%s\\n' AKIA Z7Q3XK2M5TNB4VWR >creds.txt
    printf 'host = %s-%s\\n' lighthouse 1234 >names.txt
    printf 'canary = %s-%s\\n' tbhb-private-canary 0123abcd >canary.txt
    ;;
  optional) unset GITLEAKS_CONFIG_TOML ;;
esac
status=0
"$tool" dir --no-banner --redact --verbose --config "$config" . >out.txt 2>&1 || status=$?
cat out.txt
check() {{
  if ! grep -Eq -- "$1" out.txt; then
    echo "FAIL: output does not match: $1" >&2
    exit 1
  fi
}}
if ((status != {status})); then
  echo "FAIL: exit status $status, expected {status}" >&2
  exit 1
fi
for pattern in {patterns}; do
  check "$pattern"
done
if ls "$TEST_TMPDIR"/gitleaks-private.* >/dev/null 2>&1; then
  echo "FAIL: the private config's temporary directory was left behind" >&2
  exit 1
fi
"""

def _gitleaks_private_scenario_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            patterns = " ".join(["'{}'".format(p.replace("'", "'\\''")) for p in ctx.attr.patterns]),
            scenario = ctx.attr.scenario,
            status = ctx.attr.status,
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject])
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, driver, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_private_scenario_test = rule(
    implementation = _gitleaks_private_scenario_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "patterns": attr.string_list(doc = "Extended regular expressions the output must match."),
        "scenario": attr.string(
            mandatory = True,
            values = ["clean", "empty", "findings", "no_canary", "no_committed", "optional", "other_config", "unset"],
        ),
        "status": attr.int(mandatory = True, doc = "The exit status the tool must return."),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
