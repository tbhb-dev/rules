#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

runfiles=$(cd "$(dirname "$0")/@@ROOT@@" && pwd)
config=$1
shift
export TBHB_CSPELL_CONFIG=
if [[ -n $config ]]; then
  TBHB_CSPELL_CONFIG="$PWD/$config"
  if command -v cygpath >/dev/null 2>&1; then
    TBHB_CSPELL_CONFIG=$(cygpath -m "$TBHB_CSPELL_CONFIG")
  fi
fi
shared="$runfiles/@@CONFIG@@"
if command -v cygpath >/dev/null 2>&1; then
  shared=$(cygpath -m "$shared")
fi
exec "$runfiles/@@TOOL@@" lint --no-progress --dot --config "$shared" '**' "$@"
