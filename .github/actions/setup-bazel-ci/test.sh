#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

run_tests() {
  # Exclude mutation reports and their dependents, including suites
  # and failure proofs. Mutation runs in its own nightly workflow.
  # cspell:ignore rdeps
  # The pipeline tests this function's status, so check each setup command.
  bazelisk query 'rdeps(//..., kind("mutmut_report|gomutants_report", //...))' >"$RUNNER_TEMP/mutation-excludes" || return
  echo '//...' >"$RUNNER_TEMP/test-targets" || return
  sed 's/^/-/' "$RUNNER_TEMP/mutation-excludes" >>"$RUNNER_TEMP/test-targets" || return
  bazelisk test --config=ci --target_pattern_file="$RUNNER_TEMP/test-targets"
}

# Rule: Retry only transient runner failures on macOS and log each retry.
# If retries for `tar: Write error` recur, investigate the root cause.
if [[ $RUNNER_OS != macOS ]]; then
  run_tests
  exit
fi

out=$(mktemp "$RUNNER_TEMP/bazel-test.XXXXXX")
if run_tests 2>&1 | tee "$out"; then
  exit 0
else
  # cspell:ignore PIPESTATUS
  statuses=("${PIPESTATUS[@]}")
fi

status=${statuses[0]}
if ((status == 0)); then
  exit "${statuses[1]}"
fi

if grep -qF 'Unknown host' "$out"; then
  pattern='Unknown host'
elif grep -qF 'tar: Write error' "$out"; then
  pattern='tar: Write error'
else
  exit "$status"
fi

echo "::warning::macOS Test step retried after a transient failure (matched: $pattern)"
run_tests
