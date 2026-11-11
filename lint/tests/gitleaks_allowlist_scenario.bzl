# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Exercises the committed policy with tokens suppressed by the default allowlist."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

# Split the made-up token so no credential sits in the repository's history.
GITLEAKS_ALLOWLIST_FIXTURE = """printf 'api_key = %s%s # /home/x/.codex/auth.json\\n' true Kj82Fd90cYbqJ6uV3nW7sH1p
"""

GITLEAKS_PATH_FIXTURE = """printf '<add key="Password" value="/home/x/.codex/auth.json %s%s" />\\n' Kj82Fd90 cYbqJ6uV3nW7sH1p
"""

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
subject="$PWD/{subject}"
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
work="$TEST_TMPDIR/work"
mkdir -p "$work"
cp '{config}' "$work/.gitleaks.toml"
cp '{base}' "$work/.gitleaks-rules.toml"
(
  {fixture}
) >"$work/creds.txt"
# The path regex at upstream config/gitleaks.toml:64 suppresses this value.
(
  {path_fixture}
) >"$work/nuget.config"
status=0
case {scenario} in
  defaults)
    printf '[extend]\\nuseDefault = true\\n' >"$work/defaults.toml"
    "$subject" dir --no-banner --redact --verbose --config "$work/defaults.toml" "$work/creds.txt" >"$work/out" 2>&1 || status=$?
    "$subject" dir --no-banner --redact --verbose --config "$work/defaults.toml" "$work/nuget.config" >>"$work/out" 2>&1 || status=$?
    ;;
  tree) "$subject" >"$work/out" 2>&1 || status=$? ;;
  text) BUILD_WORKSPACE_DIRECTORY="$work" "$subject" --verbose <"$work/creds.txt" >"$work/out" 2>&1 || status=$? ;;
  private)
    export GITLEAKS_CONFIG_TOML='[extend]
path = ".gitleaks.toml"
[[rules]]
id = "tbhb-private-canary"
regex = "canary-never-present"
[[rules]]
id = "credential-path"
regex = '"'''/home/[a-z]+/\\.codex/auth\\.json'''"'
'
    cd "$work"
    "$subject" dir --no-banner --redact --verbose --config .gitleaks.toml creds.txt >out 2>&1 || status=$?
    ;;
  history)
    git -C "$work" init -q
    git -C "$work" config user.email test@example.invalid
    git -C "$work" config user.name test
    git -C "$work" add creds.txt nuget.config
    git -C "$work" commit -qm fixture
    git -C "$work" rm -q creds.txt nuget.config
    git -C "$work" commit -qm removed
    BUILD_WORKSPACE_DIRECTORY="$work" "$subject" --log-opts=HEAD >"$work/out" 2>&1 || status=$?
    ;;
esac
cat "$work/out"
if [[ {scenario} == defaults ]]; then
  [[ $status == 0 ]] && grep -q 'no leaks found' "$work/out"
else
  [[ $status == 1 ]] && grep -Eq 'RuleID: +generic-api-key' "$work/out"
  if [[ {scenario} == private ]]; then
    grep -Eq 'RuleID: +credential-path' "$work/out"
  elif [[ {scenario} == history || {scenario} == tree ]]; then
    grep -Eq 'RuleID: +nuget-config-password' "$work/out"
  fi
fi
"""

def _scenario_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        _DRIVER.format(
            base = ctx.file.base.short_path,
            config = ctx.file.config.short_path,
            fixture = GITLEAKS_ALLOWLIST_FIXTURE,
            path_fixture = GITLEAKS_PATH_FIXTURE,
            git_dir = path_dir(ctx.attr.git),
            scenario = ctx.attr.scenario,
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.file.config, ctx.file.base, ctx.executable.subject, ctx.executable.git])
    for target in [ctx.attr.subject, ctx.attr.git]:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_allowlist_scenario_test = rule(
    implementation = _scenario_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "base": attr.label(default = "//:.gitleaks-rules.toml", allow_single_file = True),
        "config": attr.label(default = "//:.gitleaks.toml", allow_single_file = True),
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "scenario": attr.string(mandatory = True, values = ["defaults", "history", "private", "text", "tree"]),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
    },
)

_CONFIG_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/{git_dir}:$PATH"
"$PWD/{subject}" --check --root "$PWD/{workspace}"
"""

def _config_test_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        _CONFIG_DRIVER.format(
            git_dir = path_dir(ctx.attr.git),
            subject = ctx.executable.subject.short_path,
            workspace = ctx.file.workspace.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.file.workspace, ctx.executable.subject, ctx.executable.git])
    for target in [ctx.attr.subject, ctx.attr.git]:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_configs_test = rule(
    implementation = _config_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "subject": attr.label(default = "//lint/gitleaks:check", executable = True, cfg = "target"),
        "workspace": attr.label(default = "//:.gitleaks.toml", allow_single_file = True),
    },
)
