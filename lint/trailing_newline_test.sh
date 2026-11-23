#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
checker=${TRAILING_NEWLINE_CHECKER:-${TEST_SRCDIR:?}/${CHECKER_RLOCATIONPATH:?}}
if [[ -n ${GIT_RLOCATIONPATH:-} ]]; then
  git_tool=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH}
  export PATH="${git_tool%/*}:$PATH"
fi
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEMPLATE_DIR=''
scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/trailing-newline.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

git init -q
commit() {
  git add -A
  git -c user.name=test -c user.email=test@example.invalid commit -qm "$1"
}
run_check() {
  BUILD_WORKSPACE_DIRECTORY="$scratch" "$checker" "$1" HEAD
}

printf 'original\n' >modified.txt
printf 'no newline' >deleted.txt
printf 'no newline' >unchanged.txt
commit base
base=$(git rev-parse HEAD)

printf 'changed\n' >modified.txt
printf 'new\n' >added.txt
: >empty.txt
printf '%08191d\0data' 0 >binary.txt
rm deleted.txt
mkdir -p lint/gitleaks
printf 'excluded' >lint/gitleaks/base.toml
printf 'excluded' >lint/gitleaks/upstream.toml
ln -s unchanged.txt link
commit passing
run_check "$base"

passing=$(git rev-parse HEAD)
printf 'changed again' >modified.txt
printf 'missing newline' >'new file.txt'
printf '%08192d\0' 0 >late-nul.txt
commit failing
printf 'fixed in the worktree\n' >modified.txt

status=0
output=$(run_check "$passing" 2>&1) || status=$?
printf '%s\n' "$output"
[[ $status == 1 ]]
[[ $output == *"modified.txt': missing trailing newline"* ]]
[[ $output == *"new file.txt': missing trailing newline"* ]]
[[ $output == *"late-nul.txt': missing trailing newline"* ]]
