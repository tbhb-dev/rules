#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails when a package's condition coverage, measured by a build action with
# gobco, is below the floor. Generated from gobco_test.sh.tpl by the
# gobco_test rule; @@REPORT@@, @@FLOOR@@ and @@PACKAGE@@ are filled in at
# analysis time.
#
# The report holds covered=<outcomes the tests reached> and total=<outcomes
# there are: two for each condition>, and an uncovered=<location>: <condition
# and the outcome missed> for each condition that has one it never reached.
# The package passes when covered is at least floor percent of total, so a
# package with no conditions passes.

set -euo pipefail

report=@@REPORT@@
floor=@@FLOOR@@
package=@@PACKAGE@@

value_of() {
  local lines
  lines=$(grep -E "^$1=[0-9]+$" "$report" || true)
  if [[ -z $lines || $lines == *$'\n'* ]]; then
    echo "gobco_test: $report does not set $1 once" >&2
    exit 1
  fi
  echo "$((10#${lines#*=}))"
}

covered=$(value_of covered)
total=$(value_of total)

if ((total == 0)); then
  echo "gobco_test: $package: no conditions to cover"
  exit 0
fi

# Tenths of a percent, for the message; the check itself is exact.
tenths=$((covered * 1000 / total))
summary="$package: $covered of $total outcomes covered (${tenths%?}.${tenths: -1}%), floor $floor%"

if ((covered * 100 >= floor * total)); then
  echo "gobco_test: ok: $summary"
  exit 0
fi

echo "gobco_test: FAIL: $summary" >&2
echo "conditions with an outcome no test reached:" >&2
sed -n 's/^uncovered=/  /p' "$report" >&2
exit 1
