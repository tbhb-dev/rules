#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Exercise the workflow's actual commands without a runner or mutation tools.
set -euo pipefail
workflow=${1:-${TEST_SRCDIR:-.}/${WORKFLOW_RLOCATIONPATH:-.github/workflows/mutation-nightly.yml}}
dir=$(mktemp -d "${TMPDIR:-/tmp}/mutation-nightly-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

awk '
  /^      - name: Run mutation gates$/ { found = 1; next }
  found && /^        run: \|$/ { body = 1; next }
  body && /^          / { sub(/^          /, ""); print; next }
  body { exit }
' "$workflow" >"$dir/run.sh"
[[ -s $dir/run.sh ]] || {
  echo 'FAIL: missing mutation commands' >&2
  exit 1
}

cat >"$dir/bazelisk" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
query)
  [[ $CASE != query_failure ]] || exit 7
  [[ $CASE != empty ]] || exit 0
  echo '//example:mutation_test'
  ;;
test)
  patterns=
  for arg in "$@"; do
    case $arg in
    --target_pattern_file=*) patterns=${arg#*=} ;;
    esac
  done
  [[ -n $patterns ]] || exit 9
  cmp "$patterns" <(echo '//example:mutation_test')
  touch "$RUNNER_TEMP/test-ran"
  [[ $CASE != test_failure ]] || exit 8
  ;;
*) exit 9 ;;
esac
SH
chmod +x "$dir/bazelisk"

for scenario in success query_failure empty test_failure; do
  rm -f "$dir/test-ran"
  status=0
  PATH="$dir:$PATH" RUNNER_TEMP="$dir" CASE="$scenario" bash -euo pipefail "$dir/run.sh" || status=$?
  case $scenario in
  success) [[ $status == 0 && -f $dir/test-ran ]] ;;
  query_failure) [[ $status == 7 && ! -f $dir/test-ran ]] ;;
  empty) [[ $status != 0 && ! -f $dir/test-ran ]] ;;
  test_failure) [[ $status == 8 && -f $dir/test-ran ]] ;;
  esac || {
    echo "FAIL: $scenario returned $status" >&2
    exit 1
  }
done
echo 'PASS: mutation runs, query errors, empty selections and test failures'
