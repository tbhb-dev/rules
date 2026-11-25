#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore bootstatus launchctl simctl

# Run with Bash and jq on Linux.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export PATH="$work/bin:$PATH"
export RUNNER_TEMP="$work"
export calls="$work/calls"

script=${1:-"$(dirname "${BASH_SOURCE[0]}")/test-ios-smoke.sh"}
# Shorten the diagnostic limits for the stub while exercising the same code.
sed -E 's/run_with_limit (120|20) /run_with_limit 2 /g' "$script" >"$work/smoke.sh"

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
  'list devices --json') echo '{"devices":{"iOS":[{"name":"BAZEL_TEST_stub","udid":"stub"}]}}' ;;
  'list devices') echo devices >>"$calls" ;;
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
seq 100 | sed 's/^/log /'
if [[ $hang == log ]]; then
  exec sh -c 'sleep 8; :'
fi
STUB
chmod +x "$work/bin/"*

run_case() {
  local name=$1 expected=$2 expected_calls=$3
  local status=0 start end elapsed actual_calls leftovers launch_lines log_lines
  : >"$calls"
  start=$(date +%s%N)
  bash "$work/smoke.sh" >"$work/output" 2>&1 || status=$?
  end=$(date +%s%N)
  elapsed=$(((end - start) / 1000000))
  printf '%s %d ms (exit %d)\n' "$name" "$elapsed" "$status"
  [[ $status == "$expected" ]]
  actual_calls=$(paste -sd ' ' "$calls")
  [[ $actual_calls == "$expected_calls" ]]
  leftovers=$(find "$work" -maxdepth 1 \( -name 'ios-smoke.*' -o -name 'ios-diagnostics.*' \) -print)
  [[ -z $leftovers ]]
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

export first_status=0 first_event=PASSED retry_status=0 stub_boot_status=0 hang=none
run_case pass 0 'suite reset delete first'
export first_status=3 first_event=FAILED
run_case test-failure 3 'suite reset delete first'
export first_status=1 first_event=TIMEOUT
run_case build-failure 1 'suite reset delete first'
export first_status=3
retry_calls='suite reset delete first devices boot launch log reset delete retry'
run_case timeout-retry-pass 0 "$retry_calls"
export retry_status=3 stub_boot_status=7
run_case timeout-retry-fail 3 "$retry_calls"
grep -qx 'Boot status for stub exited with status 7' "$work/output"
export retry_status=0 stub_boot_status=0 hang=launch
run_case launch-descendant 0 "$retry_calls"
export hang=log
run_case log-descendant 0 "$retry_calls"
