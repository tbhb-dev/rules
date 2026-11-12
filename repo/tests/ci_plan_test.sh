#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Run the plan's actual jq selection and filters, without the GitHub API.
# Accept a workflow path so the same test can check an earlier revision.
# Run with bash repo/tests/ci_plan_test.sh [workflow], with jq on PATH.
set -euo pipefail
workflow=${1:-.github/workflows/ci.yml}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

workspaces=$(awk '
  /^          WORKSPACES: \|$/ { found = 1; next }
  found && /^        run: \|$/ { exit }
  found { sub(/^            /, ""); print }
' "$workflow")
plan=$(awk '
  /^          selected="/ { found = 1 }
  found && /^          echo "workspaces=/ { exit }
  found { sub(/^          /, ""); print }
' "$workflow")
[[ -n $workspaces && -n $plan ]] || {
  echo 'FAIL: missing workspace selection in the workflow' >&2
  exit 1
}
# shellcheck disable=SC2016
plan=$'files=$1\n'"$plan"
# shellcheck disable=SC2016
plan+=$'\n''printf "{\"selected\":%s,\"matrix\":%s,\"apple\":%s}\n" "$selected" "$matrix" "$apple"'

failures=0
for path in swift/defs.bzl swift/e2e/smoke/BUILD.bazel README.md; do
  printf '%s\n' "$path" >"$dir/changed"
  result=$(WORKSPACES="$workspaces" bash -euo pipefail -c "$plan" -- "$dir/changed" 2>&1) || {
    echo "FAIL: $path: $result" >&2
    exit 1
  }
  summary=$(jq -cr '"matrix=\(.matrix) apple=\(.apple)"' <<<"$result")
  echo "$path: $summary"
  if [[ $path == README.md ]]; then
    # The root-file case must retain exactly the matrix from the old filter.
    assertion='.matrix == (.selected | map(select(.id | IN("swift", "swift-smoke") | not)))'
  else
    assertion='(.matrix | length > 0) and .apple == true and .matrix == [{id: "root", dir: "."}]'
  fi
  if ! jq -e "$assertion" <<<"$result" >/dev/null; then
    echo "FAIL: $path: unexpected matrix or apple selection" >&2
    failures=$((failures + 1))
  fi
done
((failures == 0)) || exit 1
echo 'PASS: Swift changes keep a root matrix and select Apple; root changes keep the original matrix'
