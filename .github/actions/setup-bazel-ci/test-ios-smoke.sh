#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore simctl udid

set -euo pipefail

list_test_simulators() {
  xcrun simctl list devices --json |
    jq -r '.devices[][] | select(.name | startswith("BAZEL_TEST_")) | .udid'
}

reset_simulators() {
  echo 'Resetting BAZEL_TEST_ simulators'
  xcrun simctl shutdown all
  list_test_simulators |
    while IFS= read -r udid; do
      xcrun simctl delete "$udid" </dev/null || return
    done
}

log_simulator_timeout() {
  local timeout_command=timeout
  command -v timeout >/dev/null || timeout_command=gtimeout

  echo '::group::iOS simulator diagnostics after TIMEOUT'
  xcrun simctl list devices || true
  list_test_simulators |
    while IFS= read -r udid; do
      echo "Boot status for $udid (up to 120 seconds)"
      "$timeout_command" 120 xcrun simctl bootstatus "$udid" </dev/null ||
        echo "Boot status for $udid exited with status $?"
    done || true
  log show --last 10m --predicate 'subsystem == "com.apple.CoreSimulator"' | tail -n 50 || true
  echo '::endgroup::'
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

log_simulator_timeout
echo "::warning::$ios_test TIMEOUT. Retrying once with a fresh simulator."
reset_simulators
bazelisk test --config=ci --flaky_test_attempts=1 "$ios_test"
