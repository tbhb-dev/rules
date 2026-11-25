#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Chooses the Bazel test targets that the change from BASE_SHA to the
# checked-out commit can affect, with target-determinator (TD). When the
# script can't decide, it selects `//...`. Every path ends in finish, which
# writes the outputs and a line to the job summary, so no fallback is silent.
set -euo pipefail

out=${RUNNER_TEMP:?}/affected-targets
mkdir -p "$out"
file=$out/targets.txt
log=$out/target-determinator.log

# finish MODE REASON: MODE is `all` or `selected`.
finish() {
  local all=false count line targets
  if [[ $1 == all ]]; then
    all=true
    count=all
    echo '//...' >"$file"
  else
    count=$(grep -c . "$file" || true)
  fi
  targets=$(tr '\n' ' ' <"$file")
  {
    echo "all=$all"
    echo "count=$count"
    echo "reason=$2"
    echo "targets=${targets% }"
    echo "file=$file"
  } >>"${GITHUB_OUTPUT:?}"
  if [[ $all == true ]]; then
    line="Running every target (\`//...\`): $2."
  else
    line="Selected $count test targets: $2."
  fi
  printf '### Affected Bazel targets\n\n%s\n' "$line" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "affected-targets: $line"
  exit 0
}

case ${EVENT:-} in
pull_request | merge_group) ;;
push | schedule) finish all "a $EVENT run tests everything" ;;
*) finish all "unknown event '${EVENT:-}'" ;;
esac

[[ -n ${BASE_SHA:-} ]] || finish all "the $EVENT event has no base commit"
head=$(git rev-parse HEAD 2>/dev/null) || finish all 'no Git checkout'
if [[ -n ${HEAD_SHA:-} && $head != "$HEAD_SHA" ]]; then
  finish all "the checkout $head is not the event's head $HEAD_SHA"
fi
if ! git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  finish all "the base $BASE_SHA is missing from the checkout (check out with fetch-depth: 0)"
fi
changed=$(git diff --name-only --no-renames "$BASE_SHA" "$head") || finish all 'git diff failed'

# These files change the module graph, the flags or the Bazel version for
# the whole workspace, in any directory, since a module can override a
# nested one by path.
while read -r path; do
  case ${path##*/} in
  MODULE.bazel | MODULE.bazel.lock | WORKSPACE | WORKSPACE.bazel | WORKSPACE.bzlmod | .bazelversion | *bazelrc)
    finish all "$path changed"
    ;;
  esac
done <<<"$changed"

[[ -n ${TD:-} ]] || finish all 'target-determinator is unavailable on this runner'

args=(-bazel bazelisk -nocache_results -delete-cached-worktree
  -before-query-error-behavior=fatal -targets "${QUERY:?}")
read -ra opts <<<"${BAZEL_OPTS:-}"
for opt in ${opts[@]+"${opts[@]}"}; do
  args+=("-bazel-opts=$opt")
done
run=()
if command -v timeout >/dev/null; then
  run=(timeout "${TIMEOUT_MINUTES:-15}m")
fi
if ${run[@]+"${run[@]}"} "$TD" "${args[@]}" "$BASE_SHA" >"$file" 2>"$log"; then
  finish selected "target-determinator compared $BASE_SHA with $head"
else
  status=$?
  tail -n 40 "$log" >&2
  finish all "target-determinator failed with exit status $status"
fi
