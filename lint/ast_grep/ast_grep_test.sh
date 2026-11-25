#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

clean="$TEST_SRCDIR/$CLEAN_RLOCATIONPATH"
mixed="$TEST_SRCDIR/$MIXED_RLOCATIONPATH"
git="$TEST_SRCDIR/$GIT_RLOCATIONPATH"
fixtures=lint/ast_grep/testdata

expect_violation() {
  local file=$1 output status=0
  shift
  output=$("$@" 2>&1) || status=$?
  printf '%s\n' "$output"
  [[ $status == 1 && $output == *'warning[example-placeholder]'* && $output == *"$file:1:"* ]]
}

if [[ $1 == full ]]; then
  "$clean"
  expect_violation old.py "$mixed"
  exit
fi

repo="$TEST_TMPDIR/repo"
export BUILD_WORKSPACE_DIRECTORY="$repo"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR=
in_repo() { "$git" -C "$repo" "$@"; }

mkdir -p "$repo/$fixtures"
in_repo init -q -b main
in_repo config user.name 'Fixture Author'
in_repo config user.email fixture@example.com
cp "$fixtures/"{clean,old}.py "$repo/$fixtures/"
in_repo add .
in_repo commit -qm baseline
in_repo switch -qc topic
printf '\n# Topic change\n' >>"$repo/$fixtures/clean.py"
cp "$fixtures/new.py" "$repo/undeclared.py"
in_repo add .
in_repo commit -qm topic
in_repo switch -q main
printf '\n# Main advanced\n' >>"$repo/$fixtures/old.py"
in_repo add .
in_repo commit -qm upstream
in_repo switch -q topic

# Using main directly would select old.py, whose contents violate the rule.
"$mixed" --changed main
"$mixed" --changed HEAD
cp "$fixtures/new.py" "$repo/$fixtures/"
in_repo add .
expect_violation new.py "$mixed" --changed main
