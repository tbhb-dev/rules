#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails unless every mutant in the reports was killed or skipped. Generated
# from mutation_gate.sh.tpl by the mutation_gate_test rule; @@REPORTS@@ is
# filled in at analysis time.
#
# A report holds one key=value per line. Required keys, each a non-negative
# integer: total, killed, skipped, survived, timeout, suspicious, no_tests,
# segfault, interrupted (0 or 1). Optional, repeatable: mutant.<status>=<name>
# for each mutant that was not killed, listed on failure.

set -euo pipefail

reports=(@@REPORTS@@)
counts=(total killed skipped survived timeout suspicious no_tests segfault interrupted)
must_be_zero=(survived timeout suspicious no_tests segfault)

total=0 killed=0 skipped=0 survived=0 timeout=0 suspicious=0 no_tests=0 segfault=0
interrupted=0
mutants=""

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
done

echo "mutation_gate: ${#reports[@]} report(s): $total total, $killed killed, $skipped skipped"

problems=()
for key in "${must_be_zero[@]}"; do
  if ((${!key} > 0)); then
    problems+=("${!key} ${key}")
  fi
done
if ((interrupted > 0)); then
  problems+=("run was interrupted")
fi
if ((total == 0)); then
  problems+=("no mutants were generated")
fi
accounted=$((killed + skipped + survived + timeout + suspicious + no_tests + segfault))
if ((total > accounted)); then
  problems+=("$((total - accounted)) not checked")
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
