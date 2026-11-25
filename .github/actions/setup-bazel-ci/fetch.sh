#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore endgroup

# The list includes optional local targets from several workspaces. Query
# the local graph first, then fetch every listed target that it declares.
# Go tools also require the workspace to expose tbhb_rules_go. Other external
# tools are mandatory. Retry download and mirror failures within the budget;
# other query, mapping or fetch failures stop immediately. The composite
# action discards the incomplete cache on failure.
set -euo pipefail
: "${TARGETS:?}"

start=$(date +%s)
deadline=${DEADLINE:-$((start + BUDGET * 60))}
script_dir=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fetch.XXXXXX")
trap 'rm -f "$out"' EXIT

# Bazel's HttpDownloader and HttpConnector report these download failures.
download_pattern='Error downloading'       # All download URLs failed.
download_pattern+='|download failed'       # Repository download failed.
download_pattern+='|GET returned [0-9]{3}' # HTTP response error.
download_pattern+='|Connection reset'      # Connection closed during transfer.
download_pattern+='|connect timed out'     # Connection could not be established.
download_pattern+='|Read timed out'        # Transfer stalled while reading.
download_pattern+='|Unknown host'          # DNS lookup failed.

download_pattern+='|could not download Bazel' # Bazelisk could not download Bazel.
download_pattern+='|could not copy from'      # Bazelisk transfer failed.

workspace_diagnostic() {
  local bazel_command=${1:-} module=missing repo=missing git_checkout cause
  if [[ -f MODULE.bazel ]]; then
    module=present
  fi
  if [[ -e REPO.bazel ]]; then
    repo=present
  fi
  if [[ -z $bazel_command || $module == missing ]]; then
    cause="no MODULE.bazel in $workspace: the checkout is empty, stale or in the wrong directory"
  else
    cause="Bazel $bazel_command could not find a workspace from $workspace (MODULE.bazel exists)"
  fi
  {
    printf '%s\n' '::group::Bazel workspace diagnostic' "workspace: $workspace"
    printf 'pwd: '
    pwd || true
    printf '%s\n' "MODULE.bazel: $module" "REPO.bazel: $repo"
    printf 'Bazel command: %s\n' "${bazel_command:-none (workspace check failed before Bazel ran)}"
    printf '%s\n' 'ls -la:'
    # shellcheck disable=SC2012
    ls -la -- "$workspace" | head -40 || true
    if git_checkout=$(git rev-parse --is-inside-work-tree 2>/dev/null) && [[ $git_checkout == true ]]; then
      printf '%s\n' 'git rev-parse HEAD:'
      git rev-parse HEAD || true
      printf '%s\n' 'git status --short:'
      git status --short | head -20 || true
    fi
    printf '%s\n' '::endgroup::'

    cause=${cause//%/%25}
    cause=${cause//$'\r'/%0D}
    cause=${cause//$'\n'/%0A}
    printf '::error::%s\n' "$cause"
  } >&2
}

retry() {
  local delay=${RETRY_DELAY:-30} now url downloads error
  until "$@" 2>&1 | tee "$out"; do
    if grep -qF 'must be invoked from within a workspace' "$out"; then
      workspace_diagnostic "$2"
      return 1
    fi
    if ! downloads=$(grep -E "$download_pattern" "$out"); then
      # Repository rule failures put the cause after a Starlark traceback.
      # Keep it with the first error, including Bazel's timestamped form.
      error=$(awk '
        /(^|[[:space:]])ERROR:/ && !error { print; error = 1 }
        /^Error in fail:/ && !failure {
          print
          if (getline > 0) print
          failure = 1
        }
      ' "$out")
      # GitHub annotations need escaped data to retain multiple lines.
      error=${error//%/%25}
      error=${error//$'\r'/%0D}
      error=${error//$'\n'/%0A}
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
    if [[ ! -f MODULE.bazel ]]; then
      workspace_diagnostic
      exit 1
    fi
    if [[ $TARGETS == @default ]]; then
      retry bazelisk mod dump_repo_mapping ''
      mapping=$(cat "$out")
      retry bazelisk query //... --output=label
      declared=$(cat "$out")
      targets=()
      while read -r label; do
        if [[ $label == @tbhb_rules_go//* ]]; then
          grep -q '"tbhb_rules_go":' <<<"$mapping" || continue
        fi
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
