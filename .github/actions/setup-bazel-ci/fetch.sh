#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The list includes optional local targets from several workspaces. Query
# the local graph first, then fetch every listed target that it declares.
# External tools are mandatory. A query or fetch failure stops the warm job
# and the composite action discards the incomplete cache.
set -euo pipefail
: "${TARGETS:?}"

start=$(date +%s)
deadline=${DEADLINE:-$((start + BUDGET * 60))}
script_dir=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp)
trap 'rm -f "$out"' EXIT

retry() {
  local delay=30 now url
  until "$@" 2>&1 | tee "$out"; do
    now=$(date +%s)
    if ((now + delay > deadline)); then
      url=$(grep -oE 'https?://[^][:space:]" ]+' "$out" | tail -1 || true)
      echo "::error::gave up after ${BUDGET} min: ${url:-no URL in the output} kept failing"
      return 1
    fi
    sleep "$delay"
    delay=$((delay * 2))
  done
}

read -ra workspaces <<<"${WORKSPACES:-.}"
visited=""
for workspace in "${workspaces[@]}"; do
  workspace=$(cd "$workspace" && pwd)
  if grep -qxF "$workspace" <<<"$visited"; then
    continue
  fi
  visited+="$workspace"$'\n'
  (
    cd "$workspace"
    if [[ $TARGETS == @default ]]; then
      retry bazelisk query //... --output=label
      declared=$(cat "$out")
      targets=()
      while read -r label; do
        if [[ $label == //* && $label != //... ]]; then
          grep -qxF "$label" <<<"$declared" || continue
        fi
        [[ ${FETCH_ALL:-true} == true || $label != //... ]] || continue
        targets+=("$label")
      done <"$script_dir/fetch-targets.txt"
    else
      read -ra targets <<<"${TARGETS//$'\n'/ }"
    fi
    retry bazelisk fetch --config=ci "${targets[@]}"
  )
done
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  end=$(date +%s)
  echo "seconds=$((end - start))" >>"$GITHUB_OUTPUT"
fi
