#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Chooses the Bazel test targets that the change from BASE_SHA to HEAD_SHA can
# affect, with target-determinator (TD). When the script can't decide, it
# selects `//...`. Every path ends in finish, which returns the checkout to
# HEAD_SHA and writes the outputs and a line to the job summary, so no
# fallback is silent and none tests another commit. Without a checkout to
# verify, the script fails.
set -euo pipefail

out=${RUNNER_TEMP:?}/affected-targets
mkdir -p "$out"
file=$out/targets.txt
log=$out/target-determinator.log
changed=$out/changed
want=

# rand: 32 random hex digits, for a delimiter or token no input can guess.
rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# quiet COMMAND...: run COMMAND with workflow commands stopped, since its
# output can hold a file name or a log from the change.
quiet() {
  local token
  token=$(rand)
  echo "::stop-commands::$token"
  "$@" || true
  echo "::$token::"
}

# ensure_head: put the checkout back on the commit the event tests.
ensure_head() {
  local now
  now=$(git rev-parse HEAD 2>/dev/null) || now=
  [[ $now != "$want" ]] || return 0
  echo "affected-targets: checking out the event's head $want" >&2
  git checkout -q --detach "$want" || return
  now=$(git rev-parse HEAD) || return
  [[ $now == "$want" ]]
}

# finish MODE REASON: MODE is `all` or `selected`. REASON can hold a changed
# path, so it loses control characters here and Markdown in the summary.
finish() {
  local all=false count line reason=${2//[[:cntrl:]]/?} delim
  if ! ensure_head; then
    echo "affected-targets: can't check out the event's head $want; stopping" >&2
    exit 1
  fi
  if [[ $1 == all ]]; then
    all=true
    count=all
    echo '//...' >"$file"
  else
    count=$(grep -c . "$file" || true)
  fi
  # A random delimiter, which no target line can match by chance.
  delim=EOF_$(rand)
  {
    echo "all=$all"
    echo "count=$count"
    echo "reason=$reason"
    echo "file=$file"
    echo "targets<<$delim"
    cat "$file"
    echo "$delim"
  } >>"${GITHUB_OUTPUT:?}"
  if [[ $all == true ]]; then
    line="Running every target (\`//...\`): "
  else
    line="Selected $count test targets: "
  fi
  line+=$(printf '%s' "$reason" | LC_ALL=C sed 's/[[:punct:]]/\\&/g')
  printf '### Affected Bazel targets\n\n%s\n' "$line" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  quiet echo "affected-targets: $count: $reason"
  exit 0
}

# deadline SECONDS COMMAND...: run COMMAND in a process group of its own,
# with status 124 like timeout(1) when it runs past SECONDS. The group stops
# at the deadline and again once COMMAND exits, so no child it left running
# can check out the base after finish restores the event's head.
deadline() {
  local seconds=$1 pid dog status=0 _
  shift
  rm -f "$out/expired"
  set -m
  "$@" </dev/null &
  pid=$!
  set +m
  (
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep "$seconds" &
    nap=$!
    wait "$nap"
    : >"$out/expired"
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 60 &
    nap=$!
    wait "$nap"
    kill -KILL -- "-$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  dog=$!
  { wait "$pid"; } 2>/dev/null || status=$?
  kill -TERM "$dog" 2>/dev/null || true
  wait "$dog" 2>/dev/null || true
  kill -KILL -- "-$pid" 2>/dev/null || true
  for _ in {1..50}; do
    kill -0 -- "-$pid" 2>/dev/null || break
    sleep 0.1
  done
  [[ ! -e $out/expired ]] || status=124
  return "$status"
}

# drop_manual SECONDS: remove the tests tagged exactly `manual`, which
# `bazel test //...` skips too. cquery's JSON lists each tag on its own, and
# a regex over the printed list can't tell `manual` from `review, manual`.
drop_manual() {
  local status=0
  [[ -s $file ]] || return 0
  ensure_head || return
  deadline "$1" "${isolate[@]}" bazelisk cquery --output=jsonproto ${opts[@]+"${opts[@]}"} \
    "attr(tags, manual, ($QUERY))" >"$out/tags.json" || return
  jq -r '.results[]?.target.rule // empty
    | select(any(.attribute[]?; .name == "tags" and any(.stringListValue[]?; . == "manual")))
    | .name' "$out/tags.json" >"$out/manual" || return
  grep -vxFf "$out/manual" "$file" >"$out/kept" || status=$?
  ((status < 2)) || return "$status"
  mv "$out/kept" "$file"
}

if ! head=$(git rev-parse HEAD 2>/dev/null); then
  echo "affected-targets: no Git checkout, so the event's head can't be verified; stopping" >&2
  exit 1
fi
want=${HEAD_SHA:-$head}

case ${EVENT:-} in
pull_request | merge_group) ;;
push | schedule) finish all "a $EVENT run tests everything" ;;
*) finish all "unknown event '${EVENT:-}'" ;;
esac

[[ -n ${BASE_SHA:-} ]] || finish all "the $EVENT event has no base commit"
[[ $head == "$want" ]] || finish all "the checkout $head is not the event's head $want"
if ! git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  finish all "the base $BASE_SHA is missing from the checkout (check out with fetch-depth: 0)"
fi
git -c core.quotePath=false diff -z --name-only --no-renames "$BASE_SHA" "$head" >"$changed" ||
  finish all 'git diff failed'

# These files change the module graph, the flags, the Bazel version, the
# package set or the rules for the whole workspace. Match the base name, in
# any directory, since a module can override a nested one by path.
while IFS= read -r -d '' path; do
  case ${path##*/} in
  MODULE.bazel* | *.MODULE.bazel | WORKSPACE* | REPO.bazel | BUILD | BUILD.* | *.bzl | \
    .bazelrc* | *bazelrc | .bazelversion | .bazeliskrc | .bazelignore)
    finish all "$path changed"
    ;;
  esac
done <"$changed"

[[ -n ${TD:-} ]] || finish all 'target-determinator is unavailable on this runner'
minutes=${TIMEOUT_MINUTES:-15}
[[ $minutes =~ ^[1-9][0-9]*$ ]] || finish all "timeout-minutes '$minutes' is not a whole number"
# Tests set TIMEOUT_SECONDS to stop a fake run sooner.
seconds=${TIMEOUT_SECONDS:-$((minutes * 60))}

args=(-bazel bazelisk -nocache_results -delete-cached-worktree
  -before-query-error-behavior=fatal -targets "${QUERY:?}")
read -ra opts <<<"${BAZEL_OPTS:-}"
for opt in ${opts[@]+"${opts[@]}"}; do
  args+=("-bazel-opts=$opt")
done
# Repository rules run code from the change, so Bazel gets no runner
# command files to write outputs, the summary or the environment through.
isolate=(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_ENV -u GITHUB_PATH -u GITHUB_STATE)
start=$SECONDS status=0 step=target-determinator
deadline "$seconds" "${isolate[@]}" "$TD" "${args[@]}" "$BASE_SHA" >"$file" 2>"$log" || status=$?
if [[ $status == 0 ]]; then
  step='the cquery of manual tags'
  left=$((seconds + start - SECONDS))
  drop_manual "$((left > 0 ? left : 1))" 2>>"$log" || status=$?
fi
[[ $status != 0 ]] || finish selected "target-determinator compared $BASE_SHA with $head"
# The log comes from the change too.
quiet tail -n 40 "$log" >&2
[[ $status != 124 ]] || finish all "$step timed out after $seconds seconds"
finish all "$step failed with exit status $status"
