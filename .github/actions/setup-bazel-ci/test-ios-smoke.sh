#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore bootstatus datamigrator devicetypes endgroup launchctl presettle simctl udid

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

# A descendant can keep writing after the timed command exits, so read from files.
log_simulator_devices() {
  run_with_limit 20 xcrun simctl list devices >"$1/devices" 2>&1 || true
  cat "$1/devices" || true
}

log_simulator_logs() {
  run_with_limit 20 log show --last 15m --style compact \
    --predicate 'process == "launchd_sim" OR process CONTAINS "datamigrator" OR process CONTAINS "LaunchServicesMigrator" OR subsystem == "com.apple.CoreSimulator"' >"$1/log" 2>&1 || true
  if [[ -s $1/log ]]; then
    tail -n 80 "$1/log" || true
  else
    echo 'no log lines'
  fi
}

settle_simulator() (
  # Match the runner settings in apple/e2e/smoke/BUILD.bazel and swift/defs.bzl.
  local test_device='iPhone 17' test_os='27.2'
  local diagnostics='' udid='' keep_device=false start boot_status=0
  local name runtime runtime_version device_type device_name
  trap '
    if [[ -n $udid ]]; then
      if ! run_with_limit 20 xcrun simctl shutdown "$udid" >"$diagnostics/shutdown" 2>&1; then
        if [[ $keep_device == false ]] ||
          ! run_with_limit 60 xcrun simctl shutdown "$udid" >>"$diagnostics/shutdown" 2>&1; then
          echo "Could not shut down $udid"
          cat "$diagnostics/shutdown" || true
        fi
      fi
      if [[ $keep_device == false ]] &&
        ! run_with_limit 20 xcrun simctl delete "$udid" >"$diagnostics/delete" 2>&1; then
        echo "Could not delete $udid"
        cat "$diagnostics/delete" || true
      fi
    fi
    if [[ -n $diagnostics ]]; then
      rm -rf "$diagnostics" || true
    fi
    echo "##[endgroup]"
  ' EXIT
  echo '##[group]iOS simulator pre-settle'
  if ! diagnostics=$(mktemp -d "$RUNNER_TEMP/ios-presettle.XXXXXX"); then
    return 0
  fi

  if ! run_with_limit 20 xcrun simctl list runtimes --json >"$diagnostics/runtimes" 2>"$diagnostics/error" ||
    ! run_with_limit 20 jq -er --arg version "$test_os" --arg device "$test_device" "
      first(.runtimes[] | select(.platform == \"iOS\" and .isAvailable and .version == \$version
        and any(.supportedDeviceTypes[]?; .name == \$device)))
      | .identifier, .version
    " "$diagnostics/runtimes" >"$diagnostics/runtime" 2>>"$diagnostics/error" ||
    ! { IFS= read -r runtime && IFS= read -r runtime_version; } <"$diagnostics/runtime"; then
    echo 'Could not select an available iOS runtime'
    cat "$diagnostics/error" || true
    return 0
  fi

  if ! run_with_limit 20 xcrun simctl list devicetypes --json >"$diagnostics/types" 2>"$diagnostics/error" ||
    ! run_with_limit 20 jq -er --arg device "$test_device" \
      "first(.devicetypes[] | select(.name == \$device)) | .identifier, .name" \
      "$diagnostics/types" >"$diagnostics/type" 2>>"$diagnostics/error" ||
    ! { IFS= read -r device_type && IFS= read -r device_name; } <"$diagnostics/type"; then
    echo 'Could not select an iPhone device type'
    cat "$diagnostics/error" || true
    return 0
  fi

  name="BAZEL_TEST_${device_name}_${runtime_version}"
  if ! run_with_limit 20 xcrun simctl create "$name" "$device_type" "$runtime" >"$diagnostics/create" 2>"$diagnostics/error" ||
    ! IFS= read -r udid <"$diagnostics/create" || [[ -z $udid ]]; then
    echo "Could not create $name"
    cat "$diagnostics/error" || true
    # Creation can be interrupted after the device has been registered.
    if run_with_limit 20 xcrun simctl list devices --json >"$diagnostics/created-devices" 2>"$diagnostics/error" &&
      run_with_limit 20 jq -r --arg name "$name" --arg runtime "$runtime" \
        ".devices[\$runtime][]? | select(.name == \$name) | .udid" "$diagnostics/created-devices" \
        >"$diagnostics/created-udid" 2>>"$diagnostics/error"; then
      IFS= read -r udid <"$diagnostics/created-udid" || true
    fi
    return 0
  fi

  if ! run_with_limit 20 xcrun simctl boot "$udid" >"$diagnostics/boot" 2>&1; then
    echo "Could not boot $udid"
    cat "$diagnostics/boot" || true
    return 0
  fi

  start=$SECONDS
  run_with_limit 600 xcrun simctl bootstatus "$udid" -b >"$diagnostics/bootstatus" 2>&1 || boot_status=$?
  echo "Pre-settle bootstatus finished after $((SECONDS - start)) seconds (status $boot_status)"
  cat "$diagnostics/bootstatus" || true
  if ((boot_status == 0)); then
    keep_device=true
  elif ((boot_status == 124)); then
    echo "Data migration service for $udid (up to 20 seconds)"
    run_with_limit 20 xcrun simctl spawn "$udid" launchctl print system/com.apple.datamigrator >"$diagnostics/migration" 2>&1 || true
    cat "$diagnostics/migration" || true
    log_simulator_devices "$diagnostics"
    log_simulator_logs "$diagnostics"
  fi
  return 0
)

log_simulator_timeout() (
  local diagnostics boot_status
  diagnostics=$(mktemp -d "$RUNNER_TEMP/ios-diagnostics.XXXXXX") || return 0
  trap 'rm -rf "$diagnostics"' EXIT

  echo '::group::iOS simulator diagnostics after TIMEOUT'
  log_simulator_devices "$diagnostics"
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
  log_simulator_logs "$diagnostics"
  echo '::endgroup::'
)

ios_test=//:ios_app_test
bazelisk test --config=ci -- //... "-$ios_test"

events=$(mktemp "$RUNNER_TEMP/ios-smoke.XXXXXX")
trap 'rm -f "$events"' EXIT

reset_simulators
settle_simulator || true
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
