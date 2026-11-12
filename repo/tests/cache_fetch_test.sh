#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
scratch=${TEST_TMPDIR:?}/fetch
# On Windows TEST_TMPDIR is D:/..., and the drive colon would split PATH.
if command -v cygpath >/dev/null; then
  scratch=$(cygpath -u "$scratch")
fi
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
  case ${FETCH_FAILURE:-} in
    target)
      echo "ERROR: no such target '//:gazelle': target 'gazelle' not declared in package ''"
      echo 'INFO: see https://example.com/help'
      exit 1
      ;;
    download-once)
      if [[ $(wc -l <"$LOG" | tr -d ' ') != 1 ]]; then
        exit 0
      fi
      ;;
    download-always) ;;
    *)
      [[ ${FAIL_FETCH:-false} != true ]]
      exit
      ;;
  esac
  echo "${DOWNLOAD_ERROR:-ERROR: Error downloading [https://example.com/archive.tar.gz]: GET returned 503 Service Unavailable}"
  echo 'INFO: see https://example.com/help'
  exit 1
fi
MOCK
cat >"$scratch/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$SLEEP_LOG"
MOCK
chmod +x "$scratch/bin/bazelisk"
chmod +x "$scratch/bin/sleep"
export PATH="$scratch/bin:$PATH" LOG="$scratch/log" SLEEP_LOG="$scratch/sleep-log"
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
# A target error must stop immediately, even with time left to retry.
# Fake sleep keeps the old script's 30-second retry observable without waiting.
export TARGETS=//:gazelle WORKSPACES=. RETRY_DELAY=1
: >"$LOG"
: >"$SLEEP_LOG"
: >"$GITHUB_OUTPUT"
now=$(date +%s)
if FETCH_FAILURE=target BUDGET=1 DEADLINE=$((now + 31)) bash "$script" >"$scratch/failure" 2>&1; then
  echo 'FAIL: target error returned success'
  exit 1
fi
cat "$scratch/failure"
fetch_count=$(wc -l <"$LOG" | tr -d ' ')
if [[ $fetch_count != 1 ]]; then
  echo "FAIL: target error made $fetch_count fetch calls; expected 1"
  exit 1
fi
[[ ! -s $SLEEP_LOG && ! -s $GITHUB_OUTPUT ]]
grep -qF "::error::ERROR: no such target '//:gazelle': target 'gazelle' not declared in package ''" "$scratch/failure"
if grep -qF 'kept failing' "$scratch/failure"; then
  echo 'FAIL: target error reported as a download failure'
  exit 1
fi
# A transient download failure still retries, with an injectable initial delay.
: >"$LOG"
: >"$SLEEP_LOG"
now=$(date +%s)
FETCH_FAILURE=download-once BUDGET=1 DEADLINE=$((now + 60)) bash "$script"
fetch_count=$(wc -l <"$LOG" | tr -d ' ')
[[ $fetch_count == 2 ]]
sleep_delays=$(cat "$SLEEP_LOG")
[[ $sleep_delays == 1 ]]
# Exhausted download retries name only a URL on a matching failure line.
: >"$LOG"
: >"$SLEEP_LOG"
: >"$GITHUB_OUTPUT"
if FETCH_FAILURE=download-always DEADLINE=0 bash "$script" >"$scratch/failure" 2>&1; then
  echo 'FAIL: persistent download error returned success'
  exit 1
fi
fetch_count=$(wc -l <"$LOG" | tr -d ' ')
[[ $fetch_count == 1 ]]
[[ ! -s $SLEEP_LOG && ! -s $GITHUB_OUTPUT ]]
grep -qxF '::error::gave up after 0 min: https://example.com/archive.tar.gz kept failing' "$scratch/failure"
# A network failure without a URL must not borrow one from unrelated output.
if FETCH_FAILURE=download-always DOWNLOAD_ERROR='ERROR: Unknown host: example.com' DEADLINE=0 bash "$script" >"$scratch/failure" 2>&1; then
  echo 'FAIL: unknown host returned success'
  exit 1
fi
grep -qxF '::error::gave up after 0 min: no URL in the download failure kept failing' "$scratch/failure"
echo 'PASS: workspace selection, mandatory tools, custom targets, timing, fetch failure, and download retries'
