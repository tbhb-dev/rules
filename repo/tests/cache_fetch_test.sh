#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
scratch=${TEST_TMPDIR:?}/fetch
mkdir -p "$scratch/bin" "$scratch/root/go" "$scratch/root/typescript"
cat >"$scratch/bin/bazelisk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == query ]]; then
  case "$PWD" in
    */go) echo //:gazelle; echo //tests/self:govulncheck ;;
    */typescript) echo //:pnpm_audit ;;
    *) echo //:gitleaks_history; echo //tools:pip_audit ;;
  esac
else
  echo "${PWD##*/} $*" >>"$LOG"
  [[ ${FAIL_FETCH:-false} != true ]]
fi
MOCK
chmod +x "$scratch/bin/bazelisk"
export PATH="$scratch/bin:$PATH" LOG="$scratch/log"
export TARGETS=@default BUDGET=0 WORKSPACES='. go typescript . go'
export GITHUB_OUTPUT="$scratch/output"
cd "$scratch/root"
bash "$script"
for entry in 'root //:gitleaks_history' 'root //tools:pip_audit' 'go //:gazelle' 'go //tests/self:govulncheck' 'typescript //:pnpm_audit'; do
  workspace=${entry%% *}
  label=${entry#* }
  grep "^$workspace " "$LOG" | grep -qF -- "$label" || {
    echo "FAIL: missing $entry"
    exit 1
  }
done
if grep '^root ' "$LOG" | grep -qF '//:pnpm_audit'; then
  echo 'FAIL: selected a target from another workspace'
  exit 1
fi
fetch_count=$(wc -l <"$LOG" | tr -d ' ')
[[ $fetch_count == 3 ]]
# External tools must fetch in all workspaces, even when local tools differ.
for workspace in root go typescript; do
  for tool in '@bazel_tools//tools:tools_for_bazel_subcommands' '@tbhb_rules//lint:zizmor'; do
    grep "^$workspace " "$LOG" | grep -qF -- "$tool"
  done
done
grep -q '^seconds=[0-9][0-9]*$' "$GITHUB_OUTPUT"
# A failed fetch must fail the composite, with no success output.
: >"$GITHUB_OUTPUT"
if FAIL_FETCH=true bash "$script"; then
  echo 'FAIL: failed fetch returned success'
  exit 1
fi
[[ ! -s $GITHUB_OUTPUT ]]
# Explicit targets preserve the existing input behavior.
TARGETS='//:custom //:other' WORKSPACES=. bash "$script"
grep -qF 'fetch --config=ci //:custom //:other' "$LOG"
echo 'PASS: workspace selection, mandatory tools, custom targets, timing, and fetch failure'
