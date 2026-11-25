#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore simctl udid

set -euo pipefail

reset_simulators() {
  echo 'Resetting BAZEL_TEST_ simulators'
  xcrun simctl shutdown all
  xcrun simctl list devices --json |
    jq -r '.devices[][] | select(.name | startswith("BAZEL_TEST_")) | .udid' |
    while IFS= read -r udid; do
      xcrun simctl delete "$udid" </dev/null || return
    done
}

ios_test=//:ios_app_test
bazelisk test --config=ci -- //... "-$ios_test"

events=$(mktemp "$RUNNER_TEMP/ios-smoke.XXXXXX")
trap 'rm -f "$events"' EXIT

reset_simulators
if bazelisk test --config=ci --flaky_test_attempts=1 --build_event_json_file="$events" "$ios_test"; then
  exit 0
else
  status=$?
fi

# Exit code 3 means tests failed. Confirm this target's status in the build events.
if ((status != 3)) || ! jq -es --arg target "$ios_test" '
  [ .[] | select(.id.testSummary.label == $target) | .testSummary.overallStatus ] == ["TIMEOUT"]
' "$events" >/dev/null; then
  exit "$status"
fi

echo "::warning::$ios_test TIMEOUT. Retrying once with a fresh simulator."
reset_simulators
bazelisk test --config=ci --flaky_test_attempts=1 "$ios_test"
