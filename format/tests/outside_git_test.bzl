# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `format` target the way `bazel run` does, against a scratch workspace."""

def _outside_git_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = """#!/usr/bin/env bash
set -euo pipefail
workspace="$TEST_TMPDIR/workspace"
mkdir -p "$workspace"
if [[ -n "{git}" ]]; then
  # A clean checkout with files for every formatter, including a BUILD
  # file, whose formatter finds its binary through runfiles.
  export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
  git -C "$workspace" init -q
  printf 'filegroup(\n    name = "x",\n)\n' >"$workspace/BUILD.bazel"
  printf 'name = "clean"\n' >"$workspace/ok.toml"
  printf '# Clean\n\nText.\n' >"$workspace/ok.md"
  git -C "$workspace" add -A
else
  echo 'a=1' >"$workspace/bad.toml"
fi
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE
BUILD_WORKSPACE_DIRECTORY="$workspace" GIT_CEILING_DIRECTORIES="$TEST_TMPDIR" "$PWD/{subject}"
""".format(
            git = "1" if ctx.attr.git_checkout else "",
            git_dir = ctx.executable._git.short_path.rpartition("/")[0],
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject, ctx.executable._git])
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr._git[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = driver, runfiles = runfiles)]

outside_git_test = rule(
    implementation = _outside_git_test_impl,
    test = True,
    attrs = {
        "git_checkout": attr.bool(doc = "Make the workspace a clean git checkout instead of a plain directory."),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
        "_git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target"),
    },
)
