#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails unless every mutant in the reports was killed, timed out within the
# cap below, or was skipped. Generated from mutation_gate.sh.tpl by the
# mutation_gate_test rule; @@MAX_TIMEOUT_PERCENT@@, @@REPORTS@@ and
# @@REQUIRE_SCOPE@@ are filled in at analysis time.
#
# A report holds one key=value per line, in a format shared by every
# mutation runner. Required keys, each a non-negative integer: total,
# killed, lived, not_covered, timeout, errored, skipped, and interrupted
# (0 or 1). Optional: scope=full|diff (absent means full); in diff scope
# also selected and changed_units, integers. Repeatable:
# mutant.<status>=<name> for each mutant not killed, in the tool's own
# status names, and mutant.unmapped=<name> for a mutant the runner's
# selection and the tool disagree on (selected but not run, or run but not
# selected). A count above 1000000000 is malformed, and so is a report that
# lists more mutants under a verdict than its count for it (a mutant.timeout
# line with timeout=0), and one with a mutant.<status> line whose status is
# none of the above. skipped counts mutants accounted for but not gating: excluded
# by a pragma, equivalent, or not viable (they don't compile); each stays
# listed with its tool status.
#
# A timed-out mutant counts as killed and stays listed (its mutant.timeout or
# mutant.timed_out lines print). The count line goes to stdout, and to
# $GITHUB_STEP_SUMMARY when that is set.
#
# Fails on: any lived, not_covered or errored mutant; timeouts above
# MAX_TIMEOUT_PERCENT of total, in the sum and in any one report; an
# interrupted run; a report whose outcomes don't add up exactly to its total
# (mutants left unchecked, or counted twice); a mutant listed under a verdict
# whose count is lower; a mutant.not_checked line (mutmut never ran it, so
# the counts can't vouch for it); a mutant.<status> line with an unknown
# status; no mutants in the full-scope reports; any
# mutant.unmapped; in diff scope, selected other than total; and with
# require_scope=full, any diff-scope report. A diff report with no mutants
# passes: its change set touched no code with mutants.

set -euo pipefail

# Most timed-out mutants, in percent of total, that still count as killed;
# MUTATION_MAX_TIMEOUT_PERCENT in quality/private/mutation_gate.bzl, which
# the runners read too.
MAX_TIMEOUT_PERCENT=@@MAX_TIMEOUT_PERCENT@@
# Counts are parsed as text first and rejected above this, so no sum or
# product below can wrap around in 64-bit arithmetic.
MAX_COUNT=1000000000

reports=(@@REPORTS@@)
require_scope=@@REQUIRE_SCOPE@@
counts=(total killed lived not_covered timeout errored skipped interrupted)
must_be_zero=(lived not_covered errored)
# Each count with the status names the runners list its mutants under
# (mutmut's, then gomutants'), for checking the listed lines against it.
verdicts=(
  "lived:survived|lived"
  "not_covered:no_tests|not_covered"
  "timeout:timeout|timed_out"
  "errored:suspicious|segfault|infra_error"
  "skipped:skipped|caught_by_type_check|not_viable|equivalent"
)
# Every status a mutant.<status> line may carry: those above, and the
# runners' own unmapped. mutant.not_checked is known, and fails, below.
known_statuses=unmapped
for entry in "${verdicts[@]}"; do
  known_statuses+="|${entry#*:}"
done

# The counts are summed and read back through eval, which shellcheck can't see.
# shellcheck disable=SC2034
total=0 killed=0 lived=0 not_covered=0 timeout=0 errored=0 skipped=0
interrupted=0
mutants=""
problems=()
unchecked=0
full_reports=0 full_total=0
diff_reports=0 diff_total=0 changed_units=0

value_of() {
  local key=$1 report=$2 lines
  lines=$(grep -E "^${key}=" "$report" || true)
  if [[ -z $lines ]]; then
    echo "mutation_gate: $report lacks $key" >&2
    exit 1
  fi
  if [[ $lines == *$'\n'* ]]; then
    echo "mutation_gate: $report sets $key more than once" >&2
    exit 1
  fi
  local value=${lines#*=}
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "mutation_gate: $report: $key is '$value', not a non-negative integer" >&2
    exit 1
  fi
  local digits=${value#"${value%%[!0]*}"}
  local too_big=0
  if ((${#digits} > ${#MAX_COUNT})); then
    too_big=1
  elif ((${#digits} == ${#MAX_COUNT})); then
    # Equal-length digit strings compare correctly as text; that is the point.
    # shellcheck disable=SC2071
    [[ $digits > $MAX_COUNT ]] && too_big=1
  fi
  if ((too_big)); then
    echo "mutation_gate: $report: $key is '$value', above the $MAX_COUNT limit" >&2
    exit 1
  fi
  echo "$((10#$value))"
}

if ((${#reports[@]} == 0)); then
  echo "mutation_gate: FAIL: no reports" >&2
  exit 1
fi

for report in "${reports[@]}"; do
  name=$report
  report="$PWD/$report"
  for key in "${counts[@]}"; do
    value=$(value_of "$key" "$report")
    eval "$key=\$(($key + value))"
    eval "r_$key=\$value"
  done
  report_mutants=$(grep -E '^mutant\.[a-z_]+=' "$report" || true)
  mutants+=$report_mutants$'\n'
  # shellcheck disable=SC2154 # r_<key> is set by the eval above
  report_total=$r_total
  # Every mutant is counted once: the outcomes add up to the total. Fewer
  # means mutants no one checked; more means some were counted twice.
  # shellcheck disable=SC2154 # r_<key> is set by the eval above
  accounted=$((r_killed + r_lived + r_not_covered + r_timeout + r_errored + r_skipped))
  if ((report_total > accounted)); then
    unchecked=$((unchecked + report_total - accounted))
  elif ((report_total < accounted)); then
    problems+=("$name: counts add up to $accounted, above total $report_total")
  fi
  # A report with more mutants listed under a verdict than it counts for
  # that verdict contradicts itself.
  for entry in "${verdicts[@]}"; do
    key=${entry%%:*}
    listed=$(printf '%s\n' "$report_mutants" | grep -cE "^mutant\.(${entry#*:})=" || true)
    counted=r_$key
    if ((listed > ${!counted})); then
      problems+=("$name: lists $listed $key mutant(s), but $key is ${!counted}")
    fi
  done
  # A mutant mutmut never checked has no outcome, so balanced counts prove
  # nothing about it; a status no verdict names can't be reconciled at all.
  not_checked=$(grep -cE '^mutant\.not_checked=' "$report" || true)
  if ((not_checked > 0)); then
    problems+=("$name: lists $not_checked mutant.not_checked line(s): mutants no run checked")
  fi
  unknown=$(grep -E '^mutant\.' "$report" | grep -vE "^mutant\.(${known_statuses}|not_checked)=" |
    cut -d= -f1 | sort -u | paste -sd, - || true)
  if [[ -n $unknown ]]; then
    problems+=("$name: lists mutants under an unknown status: $unknown")
  fi
  # Each report on its own, so a large clean one can't hide a starved one.
  # With one report this is the sum below.
  if ((${#reports[@]} > 1 && r_timeout * 100 > report_total * MAX_TIMEOUT_PERCENT)); then
    problems+=("$name: $r_timeout timeout(s) of $report_total, above $MAX_TIMEOUT_PERCENT%")
  fi
  scope=$(grep -E '^scope=' "$report" || true)
  case $scope in
  "" | scope=full)
    full_reports=$((full_reports + 1))
    full_total=$((full_total + report_total))
    ;;
  scope=diff)
    selected=$(value_of selected "$report")
    units=$(value_of changed_units "$report")
    if ((selected != report_total)); then
      echo "mutation_gate: $report: selected is $selected, total $report_total" >&2
      exit 1
    fi
    diff_reports=$((diff_reports + 1))
    diff_total=$((diff_total + report_total))
    changed_units=$((changed_units + units))
    ;;
  *)
    echo "mutation_gate: $report: unknown ${scope}" >&2
    exit 1
    ;;
  esac
done

echo "mutation_gate: ${#reports[@]} report(s): $total total, $killed killed, $skipped skipped"
if ((diff_reports > 0)); then
  echo "mutation_gate: $diff_reports diff-scoped: $diff_total mutants of $changed_units changed unit(s)"
fi

if ((timeout > 0 && total > 0)); then
  # Tenths of a percent, rounded down. A report with timeouts but a zero
  # total is malformed: the unchecked and cap checks below fail it.
  tenths=$((timeout * 1000 / total))
  timeout_line="mutation_gate: $timeout timed out of $total ($((tenths / 10)).$((tenths % 10))%), counted as killed"
  echo "$timeout_line"
  # mutmut says timeout, gomutants timed_out; the lines print as reported.
  printf '%s\n' "$mutants" | grep -E '^mutant\.(timeout|timed_out)=' || true
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    echo "$timeout_line" >>"$GITHUB_STEP_SUMMARY"
  fi
fi

for key in "${must_be_zero[@]}"; do
  if ((${!key} > 0)); then
    problems+=("${!key} ${key}")
  fi
done
if ((timeout * 100 > total * MAX_TIMEOUT_PERCENT)); then
  problems+=("$timeout timeout(s) of $total, above $MAX_TIMEOUT_PERCENT%")
fi
if ((interrupted > 0)); then
  problems+=("run was interrupted")
fi
if ((full_reports > 0 && full_total == 0)); then
  problems+=("no mutants were generated")
fi
if ((unchecked > 0)); then
  problems+=("$unchecked not checked")
fi
unmapped=$(printf '%s\n' "$mutants" | grep -c '^mutant\.unmapped=' || true)
if ((unmapped > 0)); then
  problems+=("$unmapped unmapped")
fi
if ((diff_reports > 0)) && [[ $require_scope == full ]]; then
  problems+=("$diff_reports diff-scoped report(s), but a full run is required")
fi

if ((${#problems[@]} > 0)); then
  joined=$(printf '%s, ' "${problems[@]}")
  echo "mutation_gate: FAIL: ${joined%, }" >&2
  if [[ -n ${mutants//$'\n'/} ]]; then
    echo "mutants not killed:" >&2
    printf '%s\n' "$mutants" | sed -n 's/^mutant\.\([a-z_]*\)=\(.*\)$/  \1: \2/p' >&2
  fi
  exit 1
fi
echo "mutation_gate: ok: every mutant was killed"
