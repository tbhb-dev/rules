#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Checks the author and committer of each commit in BASE..HEAD against the
# allowed pairs. Generated from commit_identity.sh.tpl; the @@NAME@@ markers
# are filled in at analysis time. Run with `bazel run <target> -- BASE HEAD`.

set -euo pipefail

runfiles=$PWD
allowed="$runfiles/@@ALLOWED@@"
git_dir="$runfiles/@@GIT_DIR@@"

export PATH="$git_dir:$PATH"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

if (($# != 2)); then
  echo "usage: commit_identity BASE HEAD" >&2
  exit 2
fi
base=$1
head=$2

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"

for rev in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
    echo "commit_identity: FAIL: $rev is not a commit in this clone" >&2
    exit 1
  fi
done

log=$(mktemp)
trap 'rm -f "$log"' EXIT
git log --format='%H%x09%an <%ae> -> %cn <%ce>' "$base..$head" >"$log"

checked=0
failed=0
while IFS=$'\t' read -r sha pair; do
  checked=$((checked + 1))
  if ! grep -Fxq -- "$pair" "$allowed"; then
    failed=$((failed + 1))
    echo "commit_identity: FAIL: $sha author and committer are not an allowed pair: ${pair/ -> / (author) -> } (committer)" >&2
  fi
done <"$log"

if ((failed != 0)); then
  echo "commit_identity: $failed of $checked commits failed. The allowed pairs are ALLOWED_PAIRS in @tbhb_rules//lint/private:commit_identity.bzl; rewrite the commits with an allowed identity." >&2
  exit 1
fi
echo "commit_identity: $checked commits checked"
