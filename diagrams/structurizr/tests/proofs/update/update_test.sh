#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the update target against a scratch workspace and checks what it writes.
set -euo pipefail

runfiles=${RUNFILES_DIR:-${TEST_SRCDIR:?}}
update=$runfiles/$1 json=$runfiles/$2 svg=$runfiles/$3
scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/update.XXXXXX")
# The runfiles path starts with the repository name; the update writes the package path.
package=${1#*/}
package=${package%/*}

fail() {
  echo "update_test: $*" >&2
  exit 1
}

# Runs the update in a fresh workspace directory, with a stub uname that
# reports the given operating system and architecture, so the result does
# not depend on the host. Sets $workspace and $diagrams.
update_on() {
  local os=$1 arch=$2
  workspace=$(mktemp -d "$scratch/workspace.XXXXXX")
  diagrams=$workspace/$package/testdata/diagrams
  mkdir -p "$diagrams" "$workspace/bin"
  echo stale >"$diagrams/structurizr-orphan.svg"
  # The stub script expands its own arguments, so the single quotes are right.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nif [ "$1" = -s ]; then echo %s; else echo %s; fi\n' "$os" "$arch" >"$workspace/bin/uname"
  chmod +x "$workspace/bin/uname"
  PATH=$workspace/bin:$PATH BUILD_WORKSPACE_DIRECTORY=$workspace "$update"
}

# PNG bytes are only measured on macOS arm64, so the update writes them there only.
update_on Linux x86_64
[[ ! -e $diagrams/structurizr-context.png ]] || fail "update wrote a PNG off macOS arm64"
cmp -s "$json" "$workspace/$package/testdata/workspace.json" || fail "workspace.json differs from the committed copy"
cmp -s "$svg" "$diagrams/structurizr-context.svg" || fail "structurizr-context.svg differs from the committed copy"
[[ ! -e $diagrams/structurizr-orphan.svg ]] || fail "orphan SVG was not removed"
for file in "$workspace/$package/testdata/workspace.json" "$diagrams/"*; do
  mode=$(find "$file" -maxdepth 0 -perm 644)
  [[ -n $mode ]] || fail "$file does not have mode 644"
done

update_on Darwin arm64
[[ -f $diagrams/structurizr-context.png ]] || fail "macOS arm64 update wrote no PNG"

# Without a workspace directory the update refuses to run.
status=0
env -u BUILD_WORKSPACE_DIRECTORY "$update" 2>"$scratch/refusal.log" || status=$?
[[ $status == 2 ]] || fail "update without BUILD_WORKSPACE_DIRECTORY exited $status, not 2"
grep -q 'use bazel run for updates' "$scratch/refusal.log" || fail "refusal message is missing"
