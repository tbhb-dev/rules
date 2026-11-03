#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails unless every mutant in the reports was killed or skipped. Generated
# from mutation_gate.sh.tpl by the mutation_gate_test rule; @@REPORTS@@ and
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
# selected). skipped counts mutants accounted for but not gating: excluded
# by a pragma, equivalent, or not viable (they don't compile); each stays
# listed with its tool status.
#
# Fails on: any lived, not_covered, timeout or errored mutant; an
# interrupted run; mutants left unchecked (total above the sum of the
# outcomes); no mutants in the full-scope reports; any mutant.unmapped; in
# diff scope, selected other than total; and with require_scope=full, any
# diff-scope report. A diff report with no mutants passes: its change set
# touched no code with mutants.

set -euo pipefail

reports=(@@REPORTS@@)
require_scope=@@REQUIRE_SCOPE@@
counts=(total killed lived not_covered timeout errored skipped interrupted)
must_be_zero=(lived not_covered timeout errored)

total=0 killed=0 lived=0 not_covered=0 timeout=0 errored=0 skipped=0
interrupted=0
mutants=""
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
  echo "$((10#$value))"
}

if ((${#reports[@]} == 0)); then
  echo "mutation_gate: FAIL: no reports" >&2
  exit 1
fi

for report in "${reports[@]}"; do
  report="$PWD/$report"
  for key in "${counts[@]}"; do
    value=$(value_of "$key" "$report")
    eval "$key=\$(($key + value))"
  done
  mutants+=$(grep -E '^mutant\.[a-z_]+=' "$report" || true)
  mutants+=$'\n'
  report_total=$(value_of total "$report")
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

problems=()
for key in "${must_be_zero[@]}"; do
  if ((${!key} > 0)); then
    problems+=("${!key} ${key}")
  fi
done
if ((interrupted > 0)); then
  problems+=("run was interrupted")
fi
if ((full_reports > 0 && full_total == 0)); then
  problems+=("no mutants were generated")
fi
accounted=$((killed + lived + not_covered + timeout + errored + skipped))
if ((total > accounted)); then
  problems+=("$((total - accounted)) not checked")
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
