#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore bootstatus datamigrator devicetypes endgroup launchctl presettle simctl udid

# Run with Bash and jq on Linux.
set -euo pipefail

work=$(mktemp -d "${TMPDIR:-/tmp}/ios-smoke-stub.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export PATH="$work/bin:$PATH"
export RUNNER_TEMP="$work"
export calls="$work/calls"
export stub_created="$work/created"

script=${1:-"$(dirname "${BASH_SOURCE[0]}")/test-ios-smoke.sh"}
# Shorten the limits and polling interval so quick stub commands stay quick.
sed -E 's/run_with_limit (600|120|60|20) /run_with_limit 2 /g; s/^    sleep 1$/    sleep 0.05/' "$script" >"$work/smoke.sh"

cat >"$work/bin/bazelisk" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' //... '*) echo suite >>"$calls" ;;
  *' --build_event_json_file='*)
    echo first >>"$calls"
    for arg; do
      if [[ $arg == --build_event_json_file=* ]]; then
        printf '{"id":{"testSummary":{"label":"//:ios_app_test"}},"testSummary":{"overallStatus":"%s"}}\n' \
          "$first_event" >"${arg#*=}"
      fi
    done
    exit "$first_status"
    ;;
  *)
    echo retry >>"$calls"
    exit "$retry_status"
    ;;
esac
STUB

cat >"$work/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
case "${*:2}" in
  'shutdown all') echo reset >>"$calls" ;;
  'list devices --json')
    printf '%s' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"name":"BAZEL_TEST_stub","udid":"stub"}'
    if [[ -f $stub_created ]]; then
      printf ',{"name":"%s","udid":"throwaway"}' "$(cat "$stub_created")"
    fi
    printf '%s\n' ']}}'
    ;;
  'list devices')
    echo devices >>"$calls"
    echo 'stub device list'
    ;;
  'list runtimes --json')
    cat <<'JSON'
{"runtimes":[
  {"platform":"iOS","isAvailable":true,"version":"27.3","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-3",
    "supportedDeviceTypes":[{"name":"iPhone 17"}]},
  {"platform":"iOS","isAvailable":false,"version":"27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-old",
    "supportedDeviceTypes":[{"name":"iPhone 17"}]},
  {"platform":"iOS","isAvailable":true,"version":"27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
    "supportedDeviceTypes":[{"name":"iPhone Duo"}]},
  {"platform":"iOS","isAvailable":true,"version":"27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2",
    "supportedDeviceTypes":[{"name":"iPhone 17"},{"name":"iPhone Duo"}]}
]}
JSON
    ;;
  'list devicetypes --json')
    echo '{"devicetypes":[{"name":"iPhone 16","identifier":"iPhone-16"},{"name":"iPhone 17","identifier":"iPhone-17"}]}'
    ;;
  'create '*)
    echo create >>"$calls"
    [[ $3 == 'BAZEL_TEST_iPhone 17_27.2' && $4 == iPhone-17 && $5 == com.apple.CoreSimulator.SimRuntime.iOS-27-2 ]] || exit 99
    if [[ $stub_create_status == 0 || $stub_create_status == 8 ]]; then
      echo "$3" >"$stub_created"
    fi
    if [[ $stub_create_status != 0 ]]; then
      echo 'stub create failed' >&2
      exit "$stub_create_status"
    fi
    echo throwaway
    ;;
  'boot throwaway') echo presettle-boot >>"$calls"; exit "$stub_settle_boot_status" ;;
  'bootstatus throwaway -b')
    echo presettle-bootstatus >>"$calls"
    if [[ $hang == bootstatus ]]; then
      echo 'Waiting on Data Migration'
      exec sh -c 'sleep 8; :'
    fi
    exit "$stub_settle_status"
    ;;
  'spawn throwaway launchctl print system/com.apple.datamigrator')
    echo migration >>"$calls"
    echo 'stub data migration service'
    ;;
  'shutdown throwaway')
    echo presettle-shutdown >>"$calls"
    if (( $(grep -c '^presettle-shutdown$' "$calls") <= stub_shutdown_failures )); then
      echo 'stub shutdown failed' >&2
      exit 7
    fi
    ;;
  'delete throwaway')
    echo presettle-delete >>"$calls"
    if [[ -f $stub_created ]]; then
      rm "$stub_created"
    fi
    ;;
  'delete stub') echo delete >>"$calls" ;;
  'bootstatus throwaway') echo settled-boot >>"$calls" ;;
  'spawn throwaway launchctl list') echo settled-launch >>"$calls" ;;
  'bootstatus stub') echo boot >>"$calls"; exit "$stub_boot_status" ;;
  'spawn stub launchctl list')
    echo launch >>"$calls"
    if [[ $hang == launch ]]; then
      seq 20 | sed 's/^/launch /'
      exec sh -c 'sleep 8; :'
    fi
    seq 55 | sed 's/^/launch /'
    ;;
  *) exit 99 ;;
esac
STUB

cat >"$work/bin/log" <<'STUB'
#!/usr/bin/env bash
echo log >>"$calls"
[[ $* == 'show --last 15m --style compact --predicate process == "launchd_sim" OR process CONTAINS "datamigrator" OR process CONTAINS "LaunchServicesMigrator" OR subsystem == "com.apple.CoreSimulator"' ]] || exit 99
if [[ $hang == bootstatus ]]; then
  exit 0
fi
seq 100 | sed 's/^/log /'
if [[ $hang == log ]]; then
  exec sh -c 'sleep 8; :'
fi
STUB
chmod +x "$work/bin/"*

run_case() {
  local name=$1 expected=$2 expected_calls=$3
  local status=0 start end elapsed actual_calls leftovers group_starts group_ends launch_lines log_lines
  : >"$calls"
  rm -f "$stub_created"
  start=$(date +%s%N)
  "$BASH" "$work/smoke.sh" >"$work/output" 2>&1 || status=$?
  end=$(date +%s%N)
  elapsed=$(((end - start) / 1000000))
  printf '%s %d ms (exit %d)\n' "$name" "$elapsed" "$status"
  [[ $status == "$expected" ]]
  actual_calls=$(paste -sd ' ' "$calls")
  [[ $actual_calls == "$expected_calls" ]]
  leftovers=$(find "$work" -maxdepth 1 \( -name 'ios-smoke.*' -o -name 'ios-diagnostics.*' -o -name 'ios-presettle.*' \) -print)
  [[ -z $leftovers ]]
  group_starts=$(grep -Fxc '##[group]iOS simulator pre-settle' "$work/output")
  group_ends=$(grep -Fxc '##[endgroup]' "$work/output")
  [[ $group_starts == 1 && $group_ends == 1 ]]
  if [[ $expected_calls == *retry ]]; then
    launch_lines=$(grep -cx 'launch [0-9]*' "$work/output")
    log_lines=$(grep -cx 'log [0-9]*' "$work/output")
    if [[ $hang == launch ]]; then
      [[ $launch_lines == 20 ]]
    else
      [[ $launch_lines == 40 ]]
      grep -qx 'launch 40' "$work/output"
    fi
    [[ $log_lines == 80 ]]
    grep -qx 'log 21' "$work/output"
    grep -qx 'log 100' "$work/output"
  fi
  if [[ $hang != none ]]; then
    [[ $elapsed -lt 5000 ]]
  fi
}

export first_status=0 first_event=PASSED retry_status=0 stub_boot_status=0 stub_create_status=0 hang=none
export stub_settle_boot_status=0 stub_settle_status=0 stub_shutdown_failures=0
create_calls='suite reset delete create'
presettle_calls="$create_calls presettle-boot presettle-bootstatus"
first_calls="$presettle_calls presettle-shutdown first"
cleanup_calls='presettle-shutdown presettle-delete first'
run_case fast-bootstatus 0 "$first_calls"
grep -qx 'BAZEL_TEST_iPhone 17_27.2' "$stub_created"
grep -Eq '^Pre-settle bootstatus finished after [0-9]+ seconds \(status 0\)$' "$work/output"
export stub_shutdown_failures=1
run_case shutdown-retry 0 "$presettle_calls presettle-shutdown presettle-shutdown first"
grep -qx 'BAZEL_TEST_iPhone 17_27.2' "$stub_created"
export stub_shutdown_failures=2
run_case shutdown-retry-fails 0 "$presettle_calls presettle-shutdown presettle-shutdown first"
grep -qx 'Could not shut down throwaway' "$work/output"
grep -qx 'BAZEL_TEST_iPhone 17_27.2' "$stub_created"
export stub_shutdown_failures=0 stub_settle_boot_status=7
run_case boot-failure 0 "$create_calls presettle-boot $cleanup_calls"
[[ ! -e $stub_created ]]
export stub_settle_boot_status=0 stub_settle_status=7
run_case bootstatus-failure 0 "$presettle_calls $cleanup_calls"
[[ ! -e $stub_created ]]
export stub_settle_status=0
export hang=bootstatus
run_case bootstatus-descendant 0 "$presettle_calls migration devices log $cleanup_calls"
[[ ! -e $stub_created ]]
grep -Eq '^Pre-settle bootstatus finished after [0-9]+ seconds \(status 124\)$' "$work/output"
grep -qx 'Waiting on Data Migration' "$work/output"
grep -qx 'stub data migration service' "$work/output"
grep -qx 'stub device list' "$work/output"
grep -qx 'no log lines' "$work/output"
export hang=none stub_create_status=7
run_case create-failure 0 "$create_calls first"
grep -qx 'stub create failed' "$work/output"
export stub_create_status=8
run_case create-failure-after-registration 0 "$create_calls $cleanup_calls"
[[ ! -e $stub_created ]]
export stub_create_status=0
export first_status=3 first_event=FAILED
run_case test-failure 3 "$first_calls"
export first_status=1 first_event=TIMEOUT
run_case build-failure 1 "$first_calls"
export first_status=3
retry_calls="$first_calls devices boot launch settled-boot settled-launch log reset delete presettle-delete retry"
run_case timeout-retry-pass 0 "$retry_calls"
[[ ! -e $stub_created ]]
export retry_status=3 stub_boot_status=7
run_case timeout-retry-fail 3 "$retry_calls"
grep -qx 'Boot status for stub exited with status 7' "$work/output"
export retry_status=0 stub_boot_status=0 hang=launch
run_case launch-descendant 0 "$retry_calls"
export hang=log
run_case log-descendant 0 "$retry_calls"
