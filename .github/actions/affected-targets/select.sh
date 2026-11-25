#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Chooses the Bazel test targets that the change from BASE_SHA to HEAD_SHA can
# affect, with target-determinator (TD). When the script can't decide, it
# selects `//...`, since only a selection too small to cover the change is
# wrong. Every path ends in finish, which returns the checkout to HEAD_SHA,
# clean once a tool has run, and writes the outputs and a line to the job
# summary, so no fallback is silent and none tests another commit. Without a
# checkout to verify, the script fails.
set -euo pipefail

# A directory of its own for each run, so a second run in the job leaves the
# first run's file alone.
out=$(mktemp -d "${RUNNER_TEMP:?}/affected-targets.XXXXXXXX")
file=$out/targets.txt
log=$out/target-determinator.log
changed=$out/changed
want='' ran=''

# die MESSAGE: fail the step, for a checkout the script can't verify or
# restore, or bazel-opts it can't split.
die() {
  echo "affected-targets: $*; stopping" >&2
  exit 1
}

# rand: 32 random hex digits, for a delimiter or token no input can guess.
rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# show: the one way the script prints text that can hold a file name or a
# log from the change. Each line of stdin gets a prefix and a newline, with
# workflow commands stopped, so neither form of command and no unfinished
# last line can reach the runner or swallow the resume token.
show() {
  local token
  token=$(rand)
  echo "::stop-commands::$token"
  awk '{ print "  | " $0 }' || true
  echo "::$token::"
}

# clean: the tree and every submodule hold no change, untracked files
# included whatever status.showUntrackedFiles says. Git's errors go nowhere,
# since a submodule's path can hold a workflow command.
clean() {
  local changes
  changes=$(git status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) &&
    [[ -z $changes ]]
}

# at_head: HEAD is the event's head and, once a tool has run, the checkout is
# clean, since a stopped checkout can leave the base's content under the head.
at_head() {
  local now
  now=$(git rev-parse HEAD 2>/dev/null) && [[ $now == "$want" ]] || return
  [[ -z $ran ]] || clean
}

# ensure_head: put the checkout back on the commit the event tests, by force
# once a tool has run. Git's messages go through show; pipefail keeps its
# status.
ensure_head() {
  ! at_head || return 0
  echo "affected-targets: checking out the event's head $want" >&2
  git checkout -q ${ran:+-f} --detach "$want" 2>&1 | show >&2 || return
  [[ -z $ran ]] || git submodule update -q --recursive --force 2>&1 | show >&2 || return
  at_head
}

# finish MODE REASON: MODE is `all` or `selected`. REASON can hold a changed
# path, so it loses control characters here and Markdown in the summary. A
# selection holds only for the clean head the tools analyzed, so finish
# never repairs the checkout under one and falls back instead.
finish() {
  [[ $1 == all ]] || at_head || set -- all 'the checkout changed while the tools ran'
  local all=false count line reason=${2//[[:cntrl:]]/?} delim
  ensure_head || die "can't restore a clean checkout of the event's head $want"
  if [[ $1 == all ]]; then
    all=true count=all line="Running every target (\`//...\`): "
    echo '//...' >"$file"
  else
    count=$(grep -c . "$file" || true) line="Selected $count test targets: "
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
  line+=$(printf '%s' "$reason" | LC_ALL=C sed 's/[[:punct:]]/\\&/g')
  printf '### Affected Bazel targets\n\n%s\n' "$line" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "affected-targets: $count: $reason" | show
  exit 0
}

# deadline SECONDS COMMAND...: run COMMAND in a process group of its own,
# with status 124 like timeout(1) when it runs past SECONDS. The group gets
# TERM at the deadline, KILL 60 seconds later, and KILL once COMMAND exits,
# so no child it left running can check out the base after finish restores
# the event's head. The watchdog has a group of its own too, so one kill
# stops it and its sleep.
deadline() {
  local pid dog status=0 _
  rm -f "$out/expired"
  set -m
  "${@:2}" </dev/null &
  pid=$!
  (sleep "$1" && : >"$out/expired" && kill -TERM -- "-$pid" && sleep 60 && kill -KILL -- "-$pid") \
    </dev/null >/dev/null 2>&1 &
  dog=$!
  set +m
  { wait "$pid"; } 2>/dev/null || status=$?
  kill -KILL -- "-$dog" "-$pid" 2>/dev/null || true
  for _ in {1..50}; do
    kill -0 -- "-$pid" 2>/dev/null || break
    sleep 0.1
  done
  [[ ! -e $out/expired ]] || status=124
  return "$status"
}

head=$(git rev-parse HEAD 2>/dev/null) || die "no Git checkout, so the event's head can't be verified"
[[ ${BAZEL_OPTS:-} != *$'\n'* ]] || die 'bazel-opts must be one line'
want=${HEAD_SHA:-$head}
[[ -n ${HEAD_SHA:-} ]] || finish all "no event head to check the checkout $head against"

# Any other event, such as push or schedule, tests everything. An empty
# BASE_SHA fails the check of the base below.
[[ ${EVENT:-} == pull_request || ${EVENT:-} == merge_group ]] || finish all "a '${EVENT:-}' event tests everything"
[[ $head == "$want" ]] || finish all "the checkout $head is not the event's head $want"
[[ -n ${QUERY:-} && $QUERY != *$'\n'* ]] || finish all 'the query is not one line'
git cat-file -e "${BASE_SHA:-}^{commit}" 2>/dev/null ||
  finish all "the base '${BASE_SHA:-}' is missing from the checkout (check out with fetch-depth: 0)"
git -c core.quotePath=false diff -z --raw --no-renames --output="$changed" "$BASE_SHA" "$head" 2>&1 | show >&2 ||
  finish all 'git diff failed'

# A submodule's commit (mode 160000) is no file target-determinator can
# trace. The other files change the module graph, the flags, the Bazel
# version, the package set or the rules for the whole workspace. Match the
# base name, in any directory, since a module can override a nested one by
# path.
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  [[ ${meta:0:15} != *160000* ]] || finish all "the submodule $path changed"
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

# target-determinator would analyze a change on top of the head as the head.
clean || finish all "the checkout of $head has changes, or git status failed"

args=(-bazel bazelisk -nocache_results -delete-cached-worktree
  -before-query-error-behavior=fatal -targets "$QUERY")
read -ra opts <<<"${BAZEL_OPTS:-}"
args+=(${opts[@]+"${opts[@]/#/-bazel-opts=}"})
# Repository rules run code from the change, so Bazel gets no runner
# command files to write outputs, the summary or the environment through.
isolate=(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_ENV -u GITHUB_PATH -u GITHUB_STATE)
start=$SECONDS status=0 step=target-determinator ran=1
deadline "$seconds" "${isolate[@]}" "$TD" "${args[@]}" "$BASE_SHA" >"$file" 2>"$log" || status=$?
# target-determinator reports tests tagged manual too. `bazel test //...`
# can still run one through a test_suite, so any affected test whose tags
# match `manual` falls back; jq fails then.
if [[ $status == 0 && -s $file ]]; then
  step='the cquery of manual tags' left=$((seconds + start - SECONDS))
  deadline "$((left > 0 ? left : 1))" "${isolate[@]}" bazelisk cquery --output=jsonproto \
    ${opts[@]+"${opts[@]}"} "attr(tags, manual, ($QUERY))" >"$out/tags.json" 2>>"$log" || status=$?
  [[ $status != 0 ]] || jq -en --rawfile s "$file" '($s | split("\n")) as $s
    | all(inputs | .results[]?.target.rule.name; IN($s[]) | not)' "$out/tags.json" >/dev/null 2>>"$log" ||
    finish all 'an affected test is tagged manual, or its tags are unreadable'
fi
[[ $status != 0 ]] || finish selected "target-determinator compared $BASE_SHA with $head"
# The log comes from the change too.
tail -n 40 "$log" | show >&2
[[ $status != 124 ]] || finish all "$step timed out after $seconds seconds"
finish all "$step failed with exit status $status"
