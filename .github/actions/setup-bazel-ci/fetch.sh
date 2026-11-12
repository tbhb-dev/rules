#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The list includes optional local targets from several workspaces. Query
# the local graph first, then fetch every listed target that it declares.
# External tools are mandatory. Retry download and mirror failures within
# the budget; other query or fetch failures stop immediately. The composite
# action discards the incomplete cache on failure.
set -euo pipefail
: "${TARGETS:?}"

start=$(date +%s)
deadline=${DEADLINE:-$((start + BUDGET * 60))}
script_dir=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp)
trap 'rm -f "$out"' EXIT

# Bazel's HttpDownloader and HttpConnector report these download failures.
download_pattern='Error downloading'       # All download URLs failed.
download_pattern+='|download failed'       # Repository download failed.
download_pattern+='|GET returned [0-9]{3}' # HTTP response error.
download_pattern+='|Connection reset'      # Connection closed during transfer.
download_pattern+='|connect timed out'     # Connection could not be established.
download_pattern+='|Read timed out'        # Transfer stalled while reading.
download_pattern+='|Unknown host'          # DNS lookup failed.

retry() {
  local delay=${RETRY_DELAY:-30} now url downloads error
  until "$@" 2>&1 | tee "$out"; do
    if ! downloads=$(grep -E "$download_pattern" "$out"); then
      error=$(grep -m1 '^ERROR:' "$out" || true)
      echo "::error::${error:-command failed without a download error}"
      return 1
    fi
    now=$(date +%s)
    if ((now + delay > deadline)); then
      url=$(grep -oE 'https?://[^][:space:]" ]+' <<<"$downloads" | tail -1 || true)
      echo "::error::gave up after ${BUDGET} min: ${url:-no URL in the download failure} kept failing"
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
