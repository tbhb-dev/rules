# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `gitleaks_text` target on text piped in, in a throwaway workspace."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
ws="$TEST_TMPDIR/ws"
mkdir -p "$ws"
case {scenario} in
  clean | secret) printf '# Local policy only\\n' >"$ws/.gitleaks.toml" ;;
  clean_no_config) ;;
esac
case {scenario} in
  clean | clean_no_config) text='fix(ci): a title\\n\\nA body with no secret in it.\\n' ;;
  # Assembled here, so no key sits in this repository's history.
  secret) text="aws_access_key_id = AKIA""Z7Q3XK2M5TNB4VWR\\n" ;;
esac
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
        "scenario": attr.string(mandatory = True, values = ["clean", "clean_no_config", "secret"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)
