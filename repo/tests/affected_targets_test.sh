#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The affected-targets action's selection script, against a scratch Git
# repository and a fake target-determinator. Every case must end with
# outputs and a summary line, each undecidable one must select `//...`, and
# every case must leave the checkout at the event's head.

set -euo pipefail
script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
action=${TEST_SRCDIR:?}/${ACTION_RLOCATIONPATH:?}
git_bin=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH:?}
scratch=${TEST_TMPDIR:?}/affected
mkdir -p "$scratch/bin" "$scratch/repo/sub" "$scratch/no-git" "$scratch/broken-diff" "$scratch/no-timeout"
ln -s "$git_bin" "$scratch/bin/git"
# The fake records its arguments and which runner command files it can see.
# `fail` and `hang` first check out the base, as a stopped run could leave it.
cat >"$scratch/fake-td" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGS_LOG"
for name in GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_PATH GITHUB_STATE; do
  [[ -z ${!name+set} ]] || echo "$name" >>"$ENV_LOG"
done
case $FAKE in
  two) printf '//go:lib_test\n//go:cmd_test\n' ;;
  space) printf '//a:with space\n//b:t\n' ;;
  none) ;;
  fail) git checkout -q "${!#}" && echo 'ERROR: cquery failed' >&2 && exit 3 ;;
  hang) git checkout -q "${!#}" && exec sleep 30 ;;
esac
MOCK
cat >"$scratch/broken-diff/git" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do [[ \$arg != diff ]] || exit 128; done
exec "$git_bin" "\$@"
MOCK
chmod +x "$scratch/fake-td" "$scratch/broken-diff/git"
# no-timeout/ mirrors PATH without timeout(1), for the script's own deadline.
IFS=: read -ra dirs <<<"$scratch/bin:$PATH"
for dir in "${dirs[@]}"; do
  for tool in "$dir"/*; do
    name=${tool##*/}
    if [[ $name != timeout && -x $tool && ! -e $scratch/no-timeout/$name ]]; then
      ln -s "$tool" "$scratch/no-timeout/$name"
    fi
  done
done
export PATH="$scratch/bin:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CEILING_DIRECTORIES=$scratch
export RUNNER_TEMP=$scratch/tmp ARGS_LOG=$scratch/args ENV_LOG=$scratch/env TD=$scratch/fake-td
export QUERY='tests(//...)' BAZEL_OPTS='--config=ci --keep_going'
export GITHUB_OUTPUT=$scratch/output GITHUB_STEP_SUMMARY=$scratch/summary
export GITHUB_ENV=$scratch/github-env GITHUB_PATH=$scratch/github-path GITHUB_STATE=$scratch/state

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
! PATH=$scratch/no-timeout command -v timeout >/dev/null || fail 'timeout(1) is on the limited PATH'

# output KEY: KEY's value in GITHUB_OUTPUT, in either the one-line or the
# delimited form.
output() {
  awk -v key="$1" '
    delim != "" { if ($0 == delim) delim = ""; else if (mine) print; next }
    index($0, key "=") == 1 { print substr($0, length(key) + 2); next }
    (at = index($0, "<<")) && substr($0, 1, at - 1) ~ /^[A-Za-z_]+$/ {
      mine = substr($0, 1, at - 1) == key
      delim = substr($0, at + 2)
    }
  ' "$GITHUB_OUTPUT"
}

# load: read the outputs into all, count, reason, targets and alls.
load() {
  all=$(output all)
  count=$(output count)
  reason=$(output reason)
  targets=$(output targets)
  alls=$(grep -c '^all=' "$GITHUB_OUTPUT")
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
# the script from sub/ and check the outputs and the final checkout.
run() {
  local name=$1 expected_all=${4:-true} expected_count=${5:-all} want=${HEAD_SHA:-$3} now
  git checkout -q "$3"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  : >"$ENV_LOG"
  if ! (cd sub && EVENT=$2 bash "$script") >"$scratch/stdout" 2>&1; then
    cat "$scratch/stdout" >&2
    fail "$name: exited nonzero"
  fi
  load
  [[ $all == "$expected_all" ]] || fail "$name: want all=$expected_all"
  [[ $count == "$expected_count" ]] || fail "$name: want count=$expected_count"
  [[ $alls == 1 ]] || fail "$name: more than one all output"
  [[ $reason == ?* ]] || fail "$name: no reason"
  grep -qF '### Affected Bazel targets' "$GITHUB_STEP_SUMMARY" || fail "$name: no summary"
  [[ ! -s $ENV_LOG ]] || fail "$name: target-determinator saw runner command files"
  now=$(git rev-parse HEAD)
  [[ $now == "$want" ]] || fail "$name: the checkout is not $want"
  if [[ $expected_all == true ]]; then
    [[ $targets == //... ]] || fail "$name: fallback is not //..."
    grep -qxF '//...' "$RUNNER_TEMP/affected-targets/targets.txt" || fail "$name: file is not //..."
    grep -qF 'Running every target' "$GITHUB_STEP_SUMMARY" || fail "$name: summary hides the fallback"
  fi
  echo "PASS: $name: $reason"
}

export BASE_SHA=$base HEAD_SHA='' FAKE=two TIMEOUT_SECONDS=''
for event in push schedule workflow_dispatch ''; do
  run "event '$event'" "$event" "$docs_head"
done

run 'pull request' pull_request "$docs_head" false 2
[[ $targets == $'//go:lib_test\n//go:cmd_test' ]] || fail 'targets output'
grep -qF 'Selected 2 test targets' "$GITHUB_STEP_SUMMARY" || fail 'summary count'
for arg in -bazel bazelisk "-targets" "tests(//...)" -bazel-opts=--config=ci -bazel-opts=--keep_going "$base"; do
  grep -qxF -- "$arg" "$ARGS_LOG" || fail "target-determinator missed argument $arg"
done
last=$(tail -n 1 "$ARGS_LOG")
[[ $last == "$base" ]] || fail 'the base commit is not the last argument'

FAKE=space run 'label with a space' pull_request "$docs_head" false 2
[[ $targets == $'//a:with space\n//b:t' ]] || fail 'space: targets output'
grep -qxF '//a:with space' "$RUNNER_TEMP/affected-targets/targets.txt" || fail 'space: file'

HEAD_SHA=$docs_head run 'merge group' merge_group "$docs_head" false 2
HEAD_SHA=$docs_head run 'checkout behind the head' merge_group "$base"
HEAD_SHA=$base run 'checkout ahead of the head' merge_group "$docs_head"
FAKE=none run 'no affected tests' pull_request "$docs_head" false 0
[[ -z $targets ]] || fail 'empty selection'
FAKE=fail run 'tool failure' pull_request "$docs_head"
[[ $reason == *'exit status 3' ]] || fail 'failure status missing'
FAKE=hang TIMEOUT_SECONDS=1 run 'timeout' pull_request "$docs_head"
[[ $reason == *'timed out'* ]] || fail 'timeout reason missing'
FAKE=hang TIMEOUT_SECONDS=1 PATH=$scratch/no-timeout run 'timeout without timeout(1)' pull_request "$docs_head"
[[ $reason == *'timed out'* ]] || fail 'portable timeout reason missing'
TD='' run 'no tool' pull_request "$docs_head"
TIMEOUT_MINUTES=1.5 run 'bad timeout-minutes' pull_request "$docs_head"
BASE_SHA='' run 'no base' pull_request "$docs_head"
BASE_SHA=0123456789abcdef0123456789abcdef01234567 run 'base not fetched' pull_request "$docs_head"
PATH="$scratch/broken-diff:$PATH" run 'git diff failure' pull_request "$docs_head"
[[ $reason == 'git diff failed' ]] || fail 'git diff: wrong reason'

# No checkout at all: nothing to restore, and the run still falls back.
: >"$GITHUB_OUTPUT"
(cd "$scratch/no-git" && EVENT=pull_request bash "$script") >"$scratch/stdout" 2>&1 ||
  fail 'no checkout: exited nonzero'
load
[[ $all == true && $reason == 'no Git checkout' ]] || fail 'no checkout'
echo 'PASS: no checkout'

# An event head the clone lacks can't be restored, so the step fails.
git checkout -q "$docs_head"
if (cd sub && EVENT=pull_request HEAD_SHA=0123456789abcdef0123456789abcdef01234567 \
  bash "$script") >"$scratch/stdout" 2>&1; then
  fail 'unreachable head: exited zero'
fi
echo 'PASS: unreachable head'

for path in MODULE.bazel MODULE.bazel.lock .bazelrc .bazelrc.user preset.bazelrc \
  WORKSPACE WORKSPACE.bazel WORKSPACE.extra .bazelversion go/MODULE.bazel \
  go/deps.MODULE.bazel 'café/MODULE.bazel' go/BUILD go/BUILD.bazel defs/rules.bzl \
  .bazelignore REPO.bazel; do
  git checkout -q "$docs_head"
  head=$(commit "$path" src/lib.go)
  run "$path" pull_request "$head"
  [[ $reason == "$path changed" ]] || fail "$path: wrong reason"
done

# A file name can't add outputs or Markdown to the summary.
git checkout -q "$docs_head"
head=$(commit $'x\nall=false/[a](b)*_/MODULE.bazel')
run 'hostile path' pull_request "$head"
grep -qF 'x\?all\=false\/\[a\]\(b\)\*\_\/MODULE\.bazel' "$GITHUB_STEP_SUMMARY" ||
  fail 'hostile path: the summary does not escape the name'

# A rename lists only the new path unless the script turns renames off.
git checkout -q "$docs_head"
module_base=$(commit go/MODULE.bazel)
git mv go/MODULE.bazel go/MODULE.txt
git -c user.name=test -c user.email=test@example.invalid \
  -c commit.gpgsign=false commit -q -m rename
renamed=$(git rev-parse HEAD)
BASE_SHA=$module_base run 'renamed module' pull_request "$renamed"
[[ $reason == 'go/MODULE.bazel changed' ]] || fail 'rename: wrong reason'

# The default query drops the exact tag manual and keeps manual-review.
pattern=$(sed -n 's/.*attr(tags, "\([^"]*\)".*/\1/p' "$action")
[[ -n $pattern ]] || fail 'no tag pattern in the default query'
for tags in '[manual]' '[a, manual]' '[manual, b]' '[a, manual, b]'; do
  grep -qE -- "$pattern" <<<"$tags" || fail "query keeps $tags"
done
for tags in '[manual-review]' '[a, manual-review]' '[not-manual]' '[manually, b]' '[]'; do
  ! grep -qE -- "$pattern" <<<"$tags" || fail "query drops $tags"
done
echo 'PASS: manual tag pattern'
