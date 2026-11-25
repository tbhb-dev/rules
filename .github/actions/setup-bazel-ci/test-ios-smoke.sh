#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore bootstatus endgroup launchctl simctl udid

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

log_simulator_timeout() (
  run_with_limit() {
    local deadline=$((SECONDS + $1)) pid
    shift
    "$@" </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if ((SECONDS >= deadline)); then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 124
      fi
      sleep 1
    done
    wait "$pid"
  }

  local diagnostics boot_status
  diagnostics=$(mktemp -d "$RUNNER_TEMP/ios-diagnostics.XXXXXX") || return 0
  trap 'rm -rf "$diagnostics"' EXIT

  # A descendant can keep writing after the timed command exits, so read from files.
  echo '::group::iOS simulator diagnostics after TIMEOUT'
  xcrun simctl list devices || true
  list_test_simulators |
    while IFS= read -r udid; do
      echo "Boot status for $udid (up to 120 seconds)"
      boot_status=0
      run_with_limit 120 xcrun simctl bootstatus "$udid" >"$diagnostics/boot" 2>&1 || boot_status=$?
      cat "$diagnostics/boot" || true
      if ((boot_status != 0)); then
        echo "Boot status for $udid exited with status $boot_status"
      fi
      echo "Launch services for $udid (up to 20 seconds)"
      run_with_limit 20 xcrun simctl spawn "$udid" launchctl list >"$diagnostics/launch" 2>&1 || true
      head -n 40 "$diagnostics/launch" || true
      rm -f "$diagnostics/boot" "$diagnostics/launch"
    done || true
  run_with_limit 20 log show --last 10m --style compact \
    --predicate 'process == "launchd_sim" OR subsystem == "com.apple.CoreSimulator"' >"$diagnostics/log" 2>&1 || true
  tail -n 80 "$diagnostics/log" || true
  echo '::endgroup::'
)

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
