#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# repo-checks.yml retries its downloads until `retry-budget-minutes` have
# passed. A budget that leaves no room for the other steps lets the job's
# `timeout-minutes` cancel it before the retries give up. The test reads both
# defaults from the workflow and requires the budget plus the reserve to fit
# in the timeout. It also requires the diagnostics step to be bounded.
#
# WORKFLOW_RLOCATIONPATH is the workflow's runfiles path.

set -euo pipefail

workflow=${TEST_SRCDIR:?}/${WORKFLOW_RLOCATIONPATH:?}

# Minutes for the steps outside the retry budget: the Bazel setup, which
# pauses for up to 3 minutes of its own, the checkout and the scans.
reserve=5

# The default of a workflow_call input: the first `default:` line after the
# input's own line.
default_of() {
  local value
  value=$(awk -v name="$1" '
    $0 == "      " name ":" { found = 1; next }
    found && $1 == "default:" { print $2; exit }
  ' "$workflow")
  [[ $value =~ ^[0-9]+$ ]] || {
    echo "FAIL: no whole-number default for $1 in the workflow" >&2
    exit 1
  }
  echo "$value"
}

budget=$(default_of retry-budget-minutes)
timeout=$(default_of timeout-minutes)

if ((budget + reserve > timeout)); then
  echo "FAIL: retry-budget-minutes ($budget) plus $reserve reserved minutes exceeds timeout-minutes ($timeout)" >&2
  exit 1
fi
echo "retry-budget-minutes $budget + $reserve <= timeout-minutes $timeout"

# The diagnostics step runs between the two checkout attempts, so a stall in
# it would hold attempt 2 back until the job's timeout. The step must have its
# own limit, must not fail the job, and must bound its DNS lookup.
step=$(awk '
  $0 == "      - name: Show diagnostics for the failed checkout" { found = 1; print; next }
  found && /^      - name:/ { exit }
  found { print }
' "$workflow")
[[ -n $step ]] || {
  echo "FAIL: no diagnostics step in the workflow" >&2
  exit 1
}
grep -Eq '^        timeout-minutes: [0-9]+$' <<<"$step" || {
  echo "FAIL: the diagnostics step has no timeout-minutes" >&2
  exit 1
}
grep -Eq '^        continue-on-error: true$' <<<"$step" || {
  echo "FAIL: the diagnostics step lacks continue-on-error: true" >&2
  exit 1
}
grep -Eq '^ *timeout [0-9]+ getent hosts ' <<<"$step" || {
  echo "FAIL: the diagnostics step runs getent without timeout" >&2
  exit 1
}
echo "diagnostics step has timeout-minutes, continue-on-error and a bounded lookup"
