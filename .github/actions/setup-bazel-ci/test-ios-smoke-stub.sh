#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore bootstatus datamigrator launchctl presettle simctl udid

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
sed -E 's/run_with_limit (600|120|20) /run_with_limit 2 /g; s/^    sleep 1$/    sleep 0.05/' "$script" >"$work/smoke.sh"

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
    printf '%s' '{"devices":{"iOS":[{"name":"BAZEL_TEST_stub","udid":"stub"}'
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
  {"isAvailable":true,"version":"26.10","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-10"},
  {"isAvailable":true,"version":"26.9","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-9"},
  {"isAvailable":false,"version":"27.0","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0"},
  {"isAvailable":true,"version":"27.0","identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-27-0"}
]}
JSON
    ;;
  'list devicetypes --json')
    if [[ $stub_create_status == 0 ]]; then
      echo '{"devicetypes":[{"name":"iPhone 16","identifier":"iPhone-16"},{"name":"iPhone 17","identifier":"iPhone-17"}]}'
    else
      echo '{"devicetypes":[{"name":"iPad","identifier":"iPad"},{"name":"iPhone 16","identifier":"iPhone-16"},{"name":"iPhone 15","identifier":"iPhone-15"}]}'
    fi
    ;;
  'create '*)
    echo create >>"$calls"
    [[ $3 =~ ^PRESETTLE_[0-9]+$ && $5 == com.apple.CoreSimulator.SimRuntime.iOS-26-10 ]] || exit 99
    if [[ $stub_create_status != 0 ]]; then
      [[ $4 == iPhone-16 ]] || exit 99
      if [[ $stub_create_status == 8 ]]; then
        echo "$3" >"$stub_created"
      fi
      echo 'stub create failed' >&2
      exit "$stub_create_status"
    fi
    [[ $4 == iPhone-17 ]] || exit 99
    echo throwaway
    ;;
  'boot throwaway') echo presettle-boot >>"$calls" ;;
  'bootstatus throwaway -b')
    echo presettle-bootstatus >>"$calls"
    if [[ $hang == bootstatus ]]; then
      echo 'Waiting on Data Migration'
      exec sh -c 'sleep 8; :'
    fi
    ;;
  'spawn throwaway launchctl print system/com.apple.datamigrator')
    echo migration >>"$calls"
    echo 'stub data migration service'
    ;;
  'shutdown throwaway') echo presettle-shutdown >>"$calls" ;;
  'delete throwaway')
    echo presettle-delete >>"$calls"
    if [[ -f $stub_created ]]; then
      rm "$stub_created"
    fi
    ;;
  'delete stub') echo delete >>"$calls" ;;
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
  start=$(date +%s%N)
  bash "$work/smoke.sh" >"$work/output" 2>&1 || status=$?
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
presettle_calls='suite reset delete create presettle-boot presettle-bootstatus'
first_calls="$presettle_calls presettle-shutdown presettle-delete first"
run_case fast-bootstatus 0 "$first_calls"
grep -Eq '^Pre-settle bootstatus finished after [0-9]+ seconds \(status 0\)$' "$work/output"
export hang=bootstatus
run_case bootstatus-descendant 0 "$presettle_calls migration devices log presettle-shutdown presettle-delete first"
grep -Eq '^Pre-settle bootstatus finished after [0-9]+ seconds \(status 124\)$' "$work/output"
grep -qx 'Waiting on Data Migration' "$work/output"
grep -qx 'stub data migration service' "$work/output"
grep -qx 'stub device list' "$work/output"
grep -qx 'no log lines' "$work/output"
export hang=none stub_create_status=7
run_case create-failure 0 'suite reset delete create first'
grep -qx 'stub create failed' "$work/output"
export stub_create_status=8
run_case create-failure-after-registration 0 'suite reset delete create presettle-shutdown presettle-delete first'
[[ ! -e $stub_created ]]
export stub_create_status=0
export first_status=3 first_event=FAILED
run_case test-failure 3 "$first_calls"
export first_status=1 first_event=TIMEOUT
run_case build-failure 1 "$first_calls"
export first_status=3
retry_calls="$first_calls devices boot launch log reset delete retry"
run_case timeout-retry-pass 0 "$retry_calls"
export retry_status=3 stub_boot_status=7
run_case timeout-retry-fail 3 "$retry_calls"
grep -qx 'Boot status for stub exited with status 7' "$work/output"
export retry_status=0 stub_boot_status=0 hang=launch
run_case launch-descendant 0 "$retry_calls"
export hang=log
run_case log-descendant 0 "$retry_calls"
