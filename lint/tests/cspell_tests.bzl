# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis and runtime tests for cspell_test."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:util.bzl", "util")
load("//lint:defs.bzl", "cspell_test")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

def _test_args_guard_and_env(name):
    util.helper_target(
        cspell_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        config = "testdata/root/cfg.toml",
        strip_prefix = "lint/tests/testdata/root",
        tool = ":fake_tool.sh",
        env = {"EXTRA": "1"},
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_args_guard_and_env_impl, target = name + "_subject")

def _test_args_guard_and_env_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@OUTPUT_GUARD@@": "'Files checked: [1-9]'",
        "@@TOOL_ARGS@@": "'--project-config=cfg.toml'",
    })
    env.expect.that_target(target).provider(RunEnvironmentInfo).environment().contains_exactly({
        "BAZEL_BINDIR": ".",
        "EXTRA": "1",
    })

def _test_without_config(name):
    util.helper_target(
        cspell_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_without_config_impl, target = name + "_subject")

def _test_without_config_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@TOOL_ARGS@@": "",
    })

def _test_default_tool_is_the_pinned_cspell(name):
    util.helper_target(
        cspell_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_default_tool_impl, target = name + "_subject")

def _test_default_tool_impl(env, target):
    # The wrapper's runfiles still contain the pinned rules_js launcher.
    launchers = [
        f.short_path.removesuffix(".bat")
        for f in target[DefaultInfo].default_runfiles.files.to_list()
    ]
    env.expect.that_bool("lint/private/cspell/cspell_/cspell" in launchers).equals(True)

def cspell_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_args_guard_and_env,
            _test_without_config,
            _test_default_tool_is_the_pinned_cspell,
        ],
    )

_PARENT_CONFIG_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
subject="$PWD/{subject}"
fixtures="$PWD/lint/tests/testdata/vocabulary"
work="$TEST_TMPDIR/parent with spaces"
mkdir -p "$work/tree/lint/tests/testdata/vocabulary"
# Model a Windows test directory beneath a checkout with fixture exclusions.
printf '%s\\n' '{{"ignorePaths":["**/testdata/**"]}}' >"$work/cspell.json"
cd "$work/tree"
export BAZEL_BINDIR=.
dest=lint/tests/testdata/vocabulary
check() {{
  local expected=$1 pattern=$2 status=0
  shift 2
  "$subject" "$@" >"$work/output" 2>&1 || status=$?
  cat "$work/output"
  if ((status != expected)) || ! grep -Eq -- "$pattern" "$work/output"; then
    echo "FAIL: cspell exited $status, expected $expected and $pattern" >&2
    exit 1
  fi
}}
cp "$fixtures/clean.md" "$dest/clean.md"
check 0 'Files checked: 1'
rm "$dest/clean.md"
cp "$fixtures/bad.md" "$dest/bad.md"
check 1 '{bad_pattern}'
rm "$dest/bad.md"
# In-tree discovery and explicit configs still add their local vocabulary.
for file in clean.md local.md cspell.json words.txt; do
  cp "$fixtures/$file" "$dest/$file"
done
check 0 'Files checked: 4'
mv "$dest/cspell.json" "$dest/custom config.json"
check 0 'Files checked: 4' "--project-config=$dest/custom config.json"
"""

def _cspell_parent_config_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _PARENT_CONFIG_DRIVER.format(
            # cspell:disable-next-line
            bad_pattern = "bad\\.md:3:[0-9]+ - Unknown word \\(Renovatte\\)",
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject] + ctx.files.fixtures)
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, driver, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

cspell_parent_config_test = rule(
    implementation = _cspell_parent_config_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "fixtures": attr.label_list(allow_files = True, mandatory = True),
        "subject": attr.label(executable = True, cfg = "target", mandatory = True),
    },
)
