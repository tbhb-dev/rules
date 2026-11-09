#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# repo-checks.yml retries its downloads until `retry-budget-minutes` have
# passed. A budget that leaves no room for the other steps lets the job's
# `timeout-minutes` cancel it before the retries give up. The test reads both
# defaults from the workflow and requires the budget plus the reserve to fit
# in the timeout.
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
