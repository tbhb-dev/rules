#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# rumdl treats a CLI --exclude as replacing the config's list, so the root
# rumdl_test caller must repeat every entry of .rumdl.toml's exclude.
set -euo pipefail
root=$(dirname "${TEST_SRCDIR:?}/${ROOT_RLOCATIONPATH:?}")
cd "$root"

entries=$(awk '/^exclude = \[/ {on=1; next} on && /^\]/ {exit} on {gsub(/[ ",]/, ""); print}' .rumdl.toml)
[[ -n $entries ]] || {
  echo "FAIL: no exclude entries found in .rumdl.toml" >&2
  exit 1
}
caller=$(awk '/name = "rumdl_test"/ {on=1} on && /^\)/ {exit} on && !/^[[:space:]]*#/' BUILD.bazel)
status=0
while IFS= read -r entry; do
  grep -qF "\"$entry\"" <<<"$caller" || {
    echo "FAIL: the root rumdl_test exclude lacks $entry from .rumdl.toml" >&2
    status=1
  }
done <<<"$entries"
exit "$status"
