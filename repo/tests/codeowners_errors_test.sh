#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
scratch=${TEST_TMPDIR:?}/codeowners
# A Windows drive colon must not split PATH.
if command -v cygpath >/dev/null; then
  scratch=$(cygpath -u "$scratch")
fi
mkdir -p "$scratch/bin" "$scratch/caller checkout/.github" "$scratch/caller checkout/docs" "$scratch/runner"
cat >"$scratch/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$CURL_LOG"
if [[ $CURL_STATUS != 0 ]]; then
  echo 'curl: request failed' >&2
  exit "$CURL_STATUS"
fi
printf '%s\n' "$CURL_RESPONSE"
MOCK
chmod +x "$scratch/bin/curl"
export PATH="$scratch/bin:$PATH" CURL_LOG="$scratch/curl.log"
export BUILD_WORKSPACE_DIRECTORY="$scratch/caller checkout"
export GH_TOKEN=test-token GITHUB_API_URL=https://api.github.com
export GITHUB_REPOSITORY=example/repository HEAD_SHA=0123456789abcdef
export CURL_STATUS=0 CURL_RESPONSE='{"errors":[]}'

# Bazel runs the binary from its runfiles directory, not the caller's tree.
cd "$scratch/runner"
touch CODEOWNERS

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_check() {
  rm -f "$CURL_LOG"
  if output=$("$script" 2>&1); then
    status=0
  else
    status=$?
  fi
}

expect_curl() {
  [[ -f $CURL_LOG ]] || fail 'curl was not called'
  local expected actual
  expected=$(printf '%s\n' -fsSL \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/codeowners/errors?ref=$HEAD_SHA")
  actual=$(cat "$CURL_LOG")
  [[ $actual == "$expected" ]] || fail 'unexpected curl arguments or call count'
}

run_check
[[ $status == 0 ]] || fail 'missing CODEOWNERS did not pass'
[[ $output == '::notice::Skipped CODEOWNERS owner and syntax check: no CODEOWNERS file in .github/, the repository root, or docs/.' ]] || fail 'missing skip notice'
[[ ! -e $CURL_LOG ]] || fail 'missing CODEOWNERS called curl'

# Each supported location must call the API and pass with zero errors.
for codeowners in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
  touch "$BUILD_WORKSPACE_DIRECTORY/$codeowners"
  run_check
  [[ $status == 0 && -z $output ]] || fail "$codeowners with zero errors did not pass silently: $output"
  expect_curl
  rm "$BUILD_WORKSPACE_DIRECTORY/$codeowners"
done

touch "$BUILD_WORKSPACE_DIRECTORY/CODEOWNERS"
export CURL_RESPONSE='{"errors":[{"line":2,"kind":"Invalid owner","message":"Unknown team"},{"line":7,"kind":"Invalid pattern","message":"Invalid syntax"}]}'
run_check
[[ $status == 1 ]] || fail 'two errors did not fail'
expect_curl
expected_output=$'::error::CODEOWNERS has 2 owner or syntax error(s):\n  line 2: Invalid owner: Unknown team\n  line 7: Invalid pattern: Invalid syntax'
[[ $output == "$expected_output" ]] || fail "missing error details: $output"

export CURL_STATUS=22
run_check
[[ $status == 22 ]] || fail 'curl failure did not propagate'
expect_curl
[[ $output == 'curl: request failed' ]] || fail 'curl failure was hidden'

echo 'PASS: missing file, all three locations, zero errors, two errors, and curl failure'
