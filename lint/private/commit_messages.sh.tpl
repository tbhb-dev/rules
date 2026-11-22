#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Checks the subject of each non-merge commit in BASE..HEAD. Generated from
# commit_messages.sh.tpl; the @@NAME@@ markers are filled in at analysis time.
# Run with `bazel run <target> -- BASE HEAD`.

set -euo pipefail

runfiles=$PWD
git_dir="$runfiles/@@GIT_DIR@@"
subjects="$runfiles/@@SUBJECTS@@"

export PATH="$git_dir:$PATH"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

if (($# != 2)); then
  echo "usage: commit_messages BASE HEAD" >&2
  exit 2
fi
base=$1
head=$2

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"

for rev in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
    echo "commit_messages: FAIL: $rev is not a commit in this clone" >&2
    exit 1
  fi
done

shas=$(mktemp "${TMPDIR:-/tmp}/commit-messages.XXXXXX")
trap 'rm -f "$shas"' EXIT
git log --no-merges --format=%H "$base..$head" >"$shas"

checked=0
failed=0
while IFS= read -r sha; do
  sha=${sha%$'\r'}
  checked=$((checked + 1))
  if ! problems=$(git log -1 --format=%B "$sha" | "$subjects"); then
    failed=$((failed + 1))
    while IFS= read -r problem; do
      problem=${problem%$'\r'}
      echo "commit_messages: FAIL: $sha $problem" >&2
    done <<<"$problems"
  fi
done <"$shas"

if ((failed != 0)); then
  echo "commit_messages: $failed of $checked commits failed. Reword each one and force-push with lease; every commit on the branch lands on main." >&2
  exit 1
fi
echo "commit_messages: $checked commits checked"
