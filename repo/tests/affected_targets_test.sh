#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The affected-targets action's selection script, against a scratch Git
# repository and a fake target-determinator. Every case must end with
# outputs and a summary line; each undecidable one must select `//...`.

set -euo pipefail
script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
git_bin=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH:?}
scratch=${TEST_TMPDIR:?}/affected
mkdir -p "$scratch/bin" "$scratch/repo/sub"
ln -s "$git_bin" "$scratch/bin/git"
cat >"$scratch/fake-td" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGS_LOG"
case $FAKE in
  two) printf '//go:lib_test\n//go:cmd_test\n' ;;
  none) ;;
  fail) echo 'ERROR: cquery failed' >&2 && exit 3 ;;
esac
MOCK
chmod +x "$scratch/fake-td"
export PATH="$scratch/bin:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export RUNNER_TEMP=$scratch/tmp ARGS_LOG=$scratch/args TD=$scratch/fake-td
export QUERY='tests(//...)' BAZEL_OPTS='--config=ci --keep_going'
export GITHUB_OUTPUT=$scratch/output GITHUB_STEP_SUMMARY=$scratch/summary

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cd "$scratch/repo"
git init -q -b main .
commit() {
  for path in "$@"; do
    mkdir -p "$(dirname "$path")"
    echo "$RANDOM" >>"$path"
  done
  git add -A
  git -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q -m change
  git rev-parse HEAD
}
base=$(commit README.md)
docs_head=$(commit docs/guide.md)

# run CASE EVENT HEAD [EXPECTED_ALL] [EXPECTED_COUNT]: check out HEAD, run
# the script from sub/ and check the outputs.
run() {
  local name=$1 reason expected_all=${4:-true} expected_count=${5:-all}
  git checkout -q "$3"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  if ! (cd sub && EVENT=$2 bash "$script") >"$scratch/stdout" 2>&1; then
    cat "$scratch/stdout" >&2
    fail "$name: exited nonzero"
  fi
  grep -qxF "all=$expected_all" "$GITHUB_OUTPUT" || fail "$name: want all=$expected_all"
  grep -qxF "count=$expected_count" "$GITHUB_OUTPUT" || fail "$name: want count=$expected_count"
  grep -q '^reason=..' "$GITHUB_OUTPUT" || fail "$name: no reason"
  grep -qF '### Affected Bazel targets' "$GITHUB_STEP_SUMMARY" || fail "$name: no summary"
  if [[ $expected_all == true ]]; then
    grep -qxF 'targets=//...' "$GITHUB_OUTPUT" || fail "$name: fallback is not //..."
    grep -qxF '//...' "$RUNNER_TEMP/affected-targets/targets.txt" || fail "$name: file is not //..."
    grep -qF 'Running every target' "$GITHUB_STEP_SUMMARY" || fail "$name: summary hides the fallback"
  fi
  reason=$(sed -n 's/^reason=//p' "$GITHUB_OUTPUT")
  echo "PASS: $name: $reason"
}

export BASE_SHA=$base HEAD_SHA='' FAKE=two
for event in push schedule workflow_dispatch ''; do
  run "event '$event'" "$event" "$docs_head"
done

run 'pull request' pull_request "$docs_head" false 2
grep -qxF 'targets=//go:lib_test //go:cmd_test' "$GITHUB_OUTPUT" || fail 'targets output'
grep -qF 'Selected 2 test targets' "$GITHUB_STEP_SUMMARY" || fail 'summary count'
for arg in -bazel bazelisk "-targets" "tests(//...)" -bazel-opts=--config=ci -bazel-opts=--keep_going "$base"; do
  grep -qxF -- "$arg" "$ARGS_LOG" || fail "target-determinator missed argument $arg"
done
last=$(tail -n 1 "$ARGS_LOG")
[[ $last == "$base" ]] || fail 'the base commit is not the last argument'

HEAD_SHA=$docs_head run 'merge group' merge_group "$docs_head" false 2
HEAD_SHA=$base run 'head mismatch' merge_group "$docs_head"
FAKE=none run 'no affected tests' pull_request "$docs_head" false 0
grep -qxF 'targets=' "$GITHUB_OUTPUT" || fail 'empty selection'
FAKE=fail run 'tool failure' pull_request "$docs_head"
grep -qF 'exit status 3' "$GITHUB_OUTPUT" || fail 'failure status missing'
TD='' run 'no tool' pull_request "$docs_head"
BASE_SHA='' run 'no base' pull_request "$docs_head"
BASE_SHA=0123456789abcdef0123456789abcdef01234567 run 'base not fetched' pull_request "$docs_head"

for path in MODULE.bazel MODULE.bazel.lock .bazelrc preset.bazelrc WORKSPACE \
  WORKSPACE.bazel .bazelversion go/MODULE.bazel; do
  git checkout -q "$docs_head"
  head=$(commit "$path" src/lib.go)
  run "$path" pull_request "$head"
  grep -qxF "reason=$path changed" "$GITHUB_OUTPUT" || fail "$path: wrong reason"
done

# A rename lists only the new path unless the script turns renames off.
git checkout -q "$docs_head"
module_base=$(commit go/MODULE.bazel)
git mv go/MODULE.bazel go/MODULE.txt
git -c user.name=test -c user.email=test@example.invalid \
  -c commit.gpgsign=false commit -q -m rename
renamed=$(git rev-parse HEAD)
BASE_SHA=$module_base run 'renamed module' pull_request "$renamed"
grep -qxF 'reason=go/MODULE.bazel changed' "$GITHUB_OUTPUT" || fail 'rename: wrong reason'
