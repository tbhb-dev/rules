#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the update target against a scratch workspace and checks what it writes.
set -euo pipefail

runfiles=${RUNFILES_DIR:-${TEST_SRCDIR:?}}
update=$runfiles/$1 json=$runfiles/$2 svg=$runfiles/$3
workspace=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/update.XXXXXX")
package=${1%/*}
diagrams=$workspace/$package/testdata/diagrams
mkdir -p "$diagrams"
echo stale >"$diagrams/structurizr-orphan.svg"

BUILD_WORKSPACE_DIRECTORY=$workspace "$update"

fail() {
  echo "update_test: $*" >&2
  exit 1
}

cmp -s "$json" "$workspace/$package/testdata/workspace.json" || fail "workspace.json differs from the committed copy"
cmp -s "$svg" "$diagrams/structurizr-context.svg" || fail "structurizr-context.svg differs from the committed copy"
[[ ! -e $diagrams/structurizr-orphan.svg ]] || fail "orphan SVG was not removed"

for file in "$workspace/$package/testdata/workspace.json" "$diagrams/"*; do
  mode=$(find "$file" -maxdepth 0 -perm 644)
  [[ -n $mode ]] || fail "$file does not have mode 644"
done

# PNG bytes are only measured on macOS arm64, so the update writes them there only.
png=$diagrams/structurizr-context.png
os=$(uname -s)
arch=$(uname -m)
if [[ $os == Darwin && $arch == arm64 ]]; then
  [[ -f $png ]] || fail "macOS arm64 update wrote no PNG"
else
  [[ ! -e $png ]] || fail "update wrote a PNG off macOS arm64"
fi

# Without a workspace directory the update refuses to run.
status=0
env -u BUILD_WORKSPACE_DIRECTORY "$update" 2>"$workspace/refusal.log" || status=$?
[[ $status == 2 ]] || fail "update without BUILD_WORKSPACE_DIRECTORY exited $status, not 2"
grep -q 'use bazel run for updates' "$workspace/refusal.log" || fail "refusal message is missing"
