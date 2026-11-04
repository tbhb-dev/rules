#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The pinned Git finds its own helpers, with no network: the exported git's
# --exec-path is a directory that holds git-remote-https, and Git resolves
# `remote-https` to it. Runs the git target, as bazel_env's shim does.
#
# GIT_RLOCATIONPATH is the git target's runfiles path. With UNWRAPPED=1 the
# test runs the dugite-native binary the wrapper execs, as the git target ran
# before it had a wrapper; the proof that this test fails there is a target
# that sets it.

set -euo pipefail

git=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH:?}

# The directory the target's git was unpacked into: what the symlinks end at.
resolve() {
  local path=$1 link
  while [[ -L $path ]]; do
    link=$(readlink -- "$path")
    if [[ $link == /* ]]; then path=$link; else path=$(dirname -- "$path")/$link; fi
  done
  (cd -- "$(dirname -- "$path")/.." && pwd -P)
}
root=$(resolve "$git")

if [[ ${UNWRAPPED:-} == 1 ]]; then
  git=$root/bin/git
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# What a developer's shell may hold: Git exports its own GIT_EXEC_PATH to the
# hooks it runs, and those hooks may run this git.
unset GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_CONFIG_SYSTEM PREFIX
export GIT_CONFIG_GLOBAL=/dev/null

exec_path=$("$git" --exec-path)
[[ -d $exec_path ]] || fail "git --exec-path is $exec_path, which is not a directory"
[[ -x $exec_path/git-remote-https ]] || fail "git --exec-path is $exec_path, which holds no git-remote-https"

# Git runs the helper: its usage error, not "not a git command".
status=0
output=$("$git" remote-https 2>&1) || status=$?
[[ $output != *"not a git command"* ]] || fail "git remote-https: $output"
[[ $output == *usage* ]] || fail "git remote-https printed no usage (status $status): $output"

if [[ ${UNWRAPPED:-} == 1 ]]; then
  exit 0
fi

# A GIT_EXEC_PATH left by another Git does not win: that Git's helpers do not
# belong to this one.
stale=$(GIT_EXEC_PATH=/nonexistent "$git" --exec-path)
[[ $stale == "$exec_path" ]] || fail "a stale GIT_EXEC_PATH gave $stale, not $exec_path"

# A caller's choices stand. GIT_TEMPLATE_DIR= makes a repository with no
# sample hooks; unset, it gets the archive's templates.
scratch=${TEST_TMPDIR:?}
GIT_TEMPLATE_DIR='' "$git" init -q "$scratch/bare"
[[ ! -e $scratch/bare/.git/hooks/pre-commit.sample ]] || fail "an empty GIT_TEMPLATE_DIR still got the templates"
"$git" init -q "$scratch/templated"
[[ -e $scratch/templated/.git/hooks/pre-commit.sample ]] || fail "git init got no template hooks"
