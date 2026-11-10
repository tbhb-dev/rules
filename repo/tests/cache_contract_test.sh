#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
root=$(dirname "${TEST_SRCDIR:?}/${ROOT_RLOCATIONPATH:?}")
cd "$root"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

manifest=.github/actions/setup-bazel-ci/fetch-targets.txt
action=.github/actions/setup-bazel-ci/action.yml
ci=.github/workflows/ci.yml
workflows=(.github/workflows/repo-checks.yml .github/workflows/pr-text.yml)

# This literal records the source review of config.js, index.js, and post.js.
# A setup-bazel bump must revisit the key computation and this assertion.
reviewed=104e3eea9447cdaa4b00d0fb46191a3985d26ab3
for file in "$action" "${workflows[@]}"; do
  pins=$(sed -n 's/.*uses: bazel-contrib\/setup-bazel@\([^ ]*\).*/\1/p' "$file")
  unique_pins=$(sort -u <<<"$pins")
  [[ $unique_pins == "$reviewed" ]] || fail "review setup-bazel's key format after its pin changes"
  # Every setup attempt must use the same explicit file list.
  count=$(grep -c 'uses: bazel-contrib/setup-bazel@' "$file")
  lists=$(awk '
    /repository-cache: \|/ {
      getline; a=$0; sub(/^ *- /, "", a)
      getline; b=$0; sub(/^ *- /, "", b)
      getline; c=$0; sub(/^ *- /, "", c)
      print a "," b "," c
    }
  ' "$file")
  list_count=$(wc -l <<<"$lists" | tr -d ' ')
  [[ $list_count == "$count" ]] || fail "missing repository-cache list in $file"
  unique_lists=$(sort -u <<<"$lists")
  [[ $unique_lists == 'MODULE.bazel,MODULE.bazel.lock,pins/*.bzl' ]] || fail "hash list differs in $file"
  if [[ $file != "$action" ]]; then
    readers=$(grep -c 'cache-save: false' "$file")
    [[ $readers == "$count" ]] || fail "$file must only restore"
  fi
done
grep -qF "KEY-FORMAT setup-bazel@$reviewed" "$ci" || fail 'missing reviewed pin beside key computation'
grep -qF "hashFiles('MODULE.bazel', 'MODULE.bazel.lock', 'pins/*.bzl')" "$ci" || fail 'lookup hash differs'
# shellcheck disable=SC2016
grep -qF 'key=setup-bazel-1-${platform}-${arch}-repository-${HASH}' "$ci" || fail 'lookup key format differs'
for mapping in 'Linux) platform=linux' 'macOS) platform=darwin' 'Windows) platform=win32' 'X64) arch=x64' 'ARM64) arch=arm64'; do
  grep -qF "$mapping" "$ci" || fail "missing platform mapping: $mapping"
done
writers=$(grep -c 'cache-save: true' "$ci")
[[ $writers == 1 ]] || fail 'cache-warm must be the sole saver'
grep -qF "if: github.event_name == 'push' && github.ref == 'refs/heads/main'" "$ci" || fail 'warm only on main pushes'
grep -qF 'lookup-only: true' "$ci" || fail 'lookup must avoid downloading the archive'
skipped_steps=$(grep -c "if: steps.cache.outputs.cache-hit != 'true'" "$ci")
[[ $skipped_steps == 2 ]] || fail 'every step after lookup must skip exact hits'
! grep -q 'restore-keys:' "$ci" || fail 'lookup must require an exact hit'
! grep -q 'cache-version:' "${workflows[@]}" || fail 'split key family'
grep -qF "if: failure() && inputs.cache-save == 'true'" "$action" || fail 'failed warms must discard partial archives'
# The two matrices must cover the same platforms.
matrices=$(grep 'os: \[ubuntu-' "$ci" | sort -u | wc -l | tr -d ' ')
[[ $matrices == 1 ]] || fail 'warm and test matrices differ'

# Read literal build/run labels and target input values, including tools
# selected by the caller. This detects a new run-only tool in either workflow.
labels=$(awk '
  {
    for (i=1; i<=NF; i++) {
      if ($i == "bazelisk" && ($(i+1) == "run" || $(i+1) == "build")) {
        label=$(i+2)
        if (label ~ /^(@|\/\/)/) print label
      }
    }
  }
  /^      [a-z-]+-target:/ { print $2 }
  /^      [a-z-]+-target:$/ { target=1; next }
  target && /^        default:/ { print $2; target=0 }
' "${workflows[@]}" "$ci" | sort -u)
while read -r label; do
  [[ $label == //* || $label == @* ]] || continue
  grep -qxF "$label" "$manifest" || fail "run-only tool missing from fetch list: $label"
done <<<"$labels"
grep -qxF '@bazel_tools//tools:tools_for_bazel_subcommands' "$manifest" || fail 'mod tidy needs buildozer'
grep -qxF '//...' "$manifest" || fail 'fetch the test graph too'
for workflow in "${workflows[@]}"; do
  grep -qF 'bazelisk query --output=location @tbhb_rules//:.github/actions/setup-bazel-ci/fetch-targets.txt' "$workflow" || fail 'workflow must locate the one pinned fetch list'
  grep -qF '/fetch.sh"' "$workflow" || fail 'workflow must use the shared fetch implementation'
done
# shellcheck disable=SC2016
grep -qF 'DEADLINE: ${{ steps.retry_clock.outputs.deadline }}' .github/workflows/repo-checks.yml || fail 'shared fetch must use the workflow retry deadline'
echo 'PASS: shared fetch list, hash inputs, sole saver, exact lookup, and reviewed setup-bazel pin'
