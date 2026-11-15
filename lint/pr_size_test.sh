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
printf 'PASS: both limits, boundaries, free lines, exemptions, Bazel and Renovate\n'
