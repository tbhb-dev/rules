# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Runs a `mutation_changes` target against a throwaway repository."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

_DRIVER = """#!/usr/bin/env bash
set -euo pipefail
export PATH="$PWD/{git_dir}:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
# same TEXT FILE: fail unless FILE holds TEXT plus a final newline. Only
# bash and coreutils: Windows CI's MSYS2 has no diff or cmp.
same() {{
  local got
  got=$(cat "$2" && printf x)
  if [[ "$1"$'\\n' != "${{got%x}}" ]]; then
    echo "expected:" >&2
    printf '%s\\n' "$1" | cat -A >&2
    echo "got ($2):" >&2
    cat -A "$2" >&2
    exit 1
  fi
}}
# index_only NAME < TEXT: stage TEXT as NAME without a file on disk.
# Windows can't hold a quote in a file name (MSYS2 maps it to a private-use
# character), so the C-quoted name lives only in the index, skip-worktree,
# which the working-tree diff takes as is. core.protectNTFS=false lets Git
# for Windows index a name NTFS can't hold; elsewhere it is the default.
index_only() {{
  local sha
  sha=$(git hash-object -w --stdin)
  git update-index --add --cacheinfo "100644,$sha,$1"
  git update-index --skip-worktree "$1"
}}
subject="$PWD/{subject}"
slice="$PWD/{slice}"
repo="$TEST_TMPDIR/repo"
mkdir -p "$repo/src" && cd "$repo"
git init -q -b main
git config user.email test@example.invalid
git config user.name test
git config core.protectNTFS false
printf 'a\\nb\\nc\\nd\\ne\\n' > src/mod.py
printf 'x\\n' > gone.txt
printf '\\000\\001' > blob.bin
git add -A
index_only 'say "hi".txt' < <(printf 'keep\\n')
git commit -q -m base
git switch -q -c topic
# Line 2 changed, line 4 deleted, a line added at the end.
printf 'a\\nB\\nc\\ne\\nf\\n' > src/mod.py
git rm -q gone.txt
printf 'new\\n' > added.py
printf '\\000\\002' > blob.bin
git add -A
index_only 'say "hi".txt' < <(printf 'keep\\nmore\\n')
git commit -q -m topic
# An uncommitted edit counts too.
printf '0\\na\\nB\\nc\\ne\\nf\\n' > src/mod.py
base=$(git rev-parse main)
BUILD_WORKSPACE_DIRECTORY="$repo" "$subject" --base main --out "$TEST_TMPDIR/changes.json"
expected='{{
  "version": 1,
  "base": "'$base'",
  "files": {{
    "added.py": "added",
    "blob.bin": [],
    "gone.txt": "deleted",
    "say \\"hi\\".txt": [[2, 2]],
    "src/mod.py": [[1, 1], [3, 3], [5, 5], [6, 6]]
  }}
}}'
same "$expected" "$TEST_TMPDIR/changes.json"
# quality's slice keeps a unit's entries and drops the base.
printf '%s\\n' 'src/mod.py' 'say \\"hi\\".txt' 'absent.py' > "$TEST_TMPDIR/unit"
awk -f "$slice" "$TEST_TMPDIR/unit" "$TEST_TMPDIR/changes.json" > "$TEST_TMPDIR/slice.json"
sliced='{{
  "version": 1,
  "files": {{
    "say \\"hi\\".txt": [[2, 2]],
    "src/mod.py": [[1, 1], [3, 3], [5, 5], [6, 6]]
  }}
}}'
same "$sliced" "$TEST_TMPDIR/slice.json"
printf '%s\\n' 'other.py' > "$TEST_TMPDIR/none"
awk -f "$slice" "$TEST_TMPDIR/none" "$TEST_TMPDIR/changes.json" > "$TEST_TMPDIR/empty.json"
same "$(printf '{{\\n  "version": 1,\\n  "files": {{}}\\n}}')" "$TEST_TMPDIR/empty.json"
# Anything but mutation_changes' layout is refused.
printf '{{"version": 1, "files": {{}}}}\\n' > "$TEST_TMPDIR/one_line.json"
if awk -f "$slice" "$TEST_TMPDIR/none" "$TEST_TMPDIR/one_line.json" 2>/dev/null; then
  echo "expected the slice to refuse a one-line change set" >&2
  exit 1
fi
# No arguments is a usage error.
if BUILD_WORKSPACE_DIRECTORY="$repo" "$subject" 2>/dev/null; then
  echo "expected a usage error" >&2
  exit 1
fi
echo ok
"""

def _mutation_changes_test_impl(ctx):
    driver = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = driver,
        content = _DRIVER.format(
            git_dir = path_dir(ctx.attr.git),
            slice = ctx.file._slice.short_path,
            subject = ctx.executable.subject.short_path,
        ),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.subject, ctx.executable.git, ctx.file._slice])
    runfiles = runfiles.merge(ctx.attr.subject[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, driver, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

mutation_changes_test = rule(
    implementation = _mutation_changes_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    attrs = SHELL_ATTRS | {
        "git": attr.label(default = "@tbhb_rules_git//:git", executable = True, cfg = "target", allow_files = True),
        "subject": attr.label(mandatory = True, executable = True, cfg = "target"),
        "_slice": attr.label(default = "//quality/private:slice.awk", allow_single_file = True),
    },
)
