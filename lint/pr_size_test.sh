#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
runfiles=$PWD
checker=${PR_SIZE:-${TEST_SRCDIR:?}/${CHECKER_RLOCATIONPATH:?}}
counter=${TEST_SRCDIR:?}/${COUNTER_RLOCATIONPATH:?}
git=${TEST_SRCDIR:+${TEST_SRCDIR}/${GIT_RLOCATIONPATH}}
git=${git:-git}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEMPLATE_DIR=''
scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/pr-size-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
new_repo() {
  mkdir "$scratch/$1"
  cd "$scratch/$1"
  "$git" init -q
  "$git" -c user.name=test -c user.email=test@example.invalid commit -qm base --allow-empty
  base=$("$git" rev-parse HEAD)
}
commit() {
  "$git" add -A
  "$git" -c user.name=test -c user.email=test@example.invalid commit -qm change
}
lines() { awk -v n="$1" -v text="$2" 'BEGIN {for (i=0; i<n; i++) print text}'; }
check() {
  local expected=$1 code=$2 raw=$3 status=0 output
  local repo=$PWD
  output=$(cd "$runfiles" && BUILD_WORKSPACE_DIRECTORY="$repo" "$checker" "$base" HEAD 2>&1) || status=$?
  echo "$output"
  [[ $status == "$expected" && $output == *"code=$code/400 raw=$raw/1500"* ]] || exit 1
  if ((expected)); then [[ $output == *'split into stacked PRs'* ]]; fi
  if ((code > 400)); then [[ $output == *'400 added Code lines'* ]]; fi
  if ((raw > 1500)); then [[ $output == *'1500 raw added lines'* ]]; fi
}
count_json() {
  local code=$1 raw=$2 failed=$3 output
  local repo=$PWD
  output=$(cd "$runfiles" && BUILD_WORKSPACE_DIRECTORY="$repo" "$counter" "$base" HEAD)
  echo "$output"
  [[ $output == "{\"code_lines\": $code, \"code_limit\": 400, \"raw_lines\": $raw, \"raw_limit\": 1500, \"failed\": $failed}" ]]
}
new_repo code_limit
lines 400 'x = 1' >source.py
commit
check 0 400 400
count_json 400 400 null
lines 401 'x = 1' >source.py
commit
check 1 401 401
count_json 401 401 '"code"'
new_repo raw_limit
lines 1500 'key: value' >config.yaml
commit
check 0 0 1500
lines 1501 'key: value' >config.yaml
commit
check 1 0 1501
new_repo free_lines
lines 2000 'x = 1' >source.py
commit
base=$("$git" rev-parse HEAD)
{
  lines 401 '# comment'
  lines 401 ''
} >source.py
commit
check 0 0 802
new_repo exemptions
mkdir -p .github vendor third_party testdata fixtures __snapshots__ golden
printf 'local/*\n' >.github/pr-size-exempt.txt
printf 'marked.py linguist-generated\nvendored.py linguist-vendored\n' >.gitattributes
printf '# Code generated; DO NOT EDIT.\n' >generated.py
commit
base=$("$git" rev-parse HEAD)
mkdir local
for path in MODULE.bazel.lock go.sum pnpm-lock.yaml uv.lock Cargo.lock \
  vendor/a.py third_party/a.py testdata/a.py fixtures/a.py __snapshots__/a.py \
  golden/a.py result.golden local/a.py marked.py vendored.py readme.md data.csv; do
  lines 1600 'x = 1' >"$path"
done
lines 1600 'x = 1' >>generated.py
printf '\0binary\n' >binary.py
commit
check 0 0 0
for path in BUILD BUILD.bazel MODULE.bazel tool.bzl; do
  new_repo "$path"
  lines 401 'x = 1' >"$path"
  commit
  check 1 401 401
done
PR_AUTHOR='tbhb-dev-renovate[bot]' check 0 0 0
bootstrap_repo() {
  mkdir "$scratch/$1"
  cd "$scratch/$1"
  "$git" init -q
  "$git" -c user.name=test -c user.email=test@example.invalid commit -qm 'Initial commit' --allow-empty
  base=$("$git" rev-parse HEAD)
}
# The baseline PR is skipped only while main's live tip is its single root
# commit and its base is that commit. The root carries no trailer.
big() {
  lines 401 'x = 1' >source.py
  commit
}
skip() { (
  export MAIN_TIP=${MAIN_TIP-$base}
  "$@"
); }
bootstrap_repo initial_pr
lines 3000 'x = 1' >source.py
commit
skip check 0 0 0
skip count_json 0 0 null
# A missing or mismatched live tip leaves the limit on.
bootstrap_repo no_inputs
big
check 1 401 401
MAIN_TIP=0000000000000000000000000000000000000000 skip check 1 401 401
MAIN_TIP='' skip check 1 401 401
# Once main moves past the root, the tip no longer matches the base.
bootstrap_repo moved
tip=$base
echo first >first.txt
commit
base=$("$git" rev-parse HEAD)
lines 401 'x = 1' >second.py
commit
MAIN_TIP=$tip skip check 1 401 401
# A stale root base never qualifies once main has a newer tip, even though the
# base is still a single root commit.
bootstrap_repo stale_base
root=$base
echo first >first.txt
commit
tip=$("$git" rev-parse HEAD)
base=$root
big
MAIN_TIP=$tip skip check 1 401 401
# A shallow clone can't prove the base is the only commit: here the base is a
# shallow boundary that looks like a root.
bootstrap_repo shallow_base
echo first >first.txt
commit
base=$("$git" rev-parse HEAD)
big
"$git" clone -q --depth 2 "file://$PWD" "$scratch/shallow_clone"
cd "$scratch/shallow_clone"
skip check 1 401 401
# A base that is not the single root commit never qualifies, even when it is
# main's tip.
bootstrap_repo two_commits
echo first >first.txt
commit
base=$("$git" rev-parse HEAD)
big
skip check 1 401 401
printf 'PASS: both limits, boundaries, free lines, exemptions, Bazel, Renovate and the root-commit baseline\n'
