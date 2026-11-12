#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

runfiles=$(cd "$(dirname "$0")/@@ROOT@@" && pwd)
export TBHB_CSPELL_CONFIG=
if [[ ${1-} == --project-config=* ]]; then
  TBHB_CSPELL_CONFIG="$PWD/${1#--project-config=}"
  shift
  if command -v cygpath >/dev/null 2>&1; then
    TBHB_CSPELL_CONFIG=$(cygpath -m "$TBHB_CSPELL_CONFIG")
  fi
fi
shared="$runfiles/@@CONFIG@@"
if command -v cygpath >/dev/null 2>&1; then
  shared=$(cygpath -m "$shared")
fi
tool="$runfiles/@@TOOL@@"
args=(lint --dot --config "$shared" '**')
if ! command -v cygpath >/dev/null 2>&1; then
  exec "$tool" "${args[@]}" --no-progress "$@"
fi

log=$(mktemp "$TEST_TMPDIR/cspell.XXXXXX")
status=0
"$tool" "${args[@]}" --no-progress "$@" >"$log" 2>&1 || status=$?
cat "$log"
if grep -Eq 'Files checked: 0([,. ]|$)' "$log"; then
  echo "cspell: zero files checked on Windows; rerunning with skip reasons" >&2
  # Progress carries skippedReason; --no-progress hides it even with --verbose.
  # Omit the diagnostic summary so it cannot satisfy tree_check's guard.
  "$tool" "${args[@]}" "$@" --verbose --debug --no-summary >&2 || true
  # Diagnostics must never turn the original zero-file run into a pass.
  if ((status == 0)); then
    status=1
  fi
fi
rm -f "$log"
exit "$status"
