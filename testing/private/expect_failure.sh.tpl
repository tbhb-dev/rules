#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the wrapped test and passes only if it fails with output matching the
# pattern. Generated from expect_failure.sh.tpl by the expect_failure_test
# rule; the @@NAME@@ markers are filled in at analysis time.

set -uo pipefail

wrapped="$PWD/@@TEST@@"
pattern=@@PATTERN@@
want_status=@@STATUS@@
first_line_only=@@FIRST_LINE@@

work="$TEST_TMPDIR/expect_failure"
log="$work/output.log"
mkdir -p "$work/tmp" "$work/outputs"

# The wrapped test gets scratch space of its own and none of the files Bazel
# collects from this test, so it cannot overwrite this test's results.
status=0
(
  export TEST_TMPDIR="$work/tmp"
  export HOME="$work/tmp"
  export TEST_UNDECLARED_OUTPUTS_DIR="$work/outputs"
  unset XML_OUTPUT_FILE TEST_PREMATURE_EXIT_FILE TEST_WARNINGS_OUTPUT_FILE \
    TEST_SHARD_STATUS_FILE TEST_INFRASTRUCTURE_FAILURE_FILE \
    TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR TEST_UNUSED_RUNFILES_LOG_FILE
  exec "$wrapped" "$@"
) >"$log" 2>&1 || status=$?

show_output() {
  echo "--- output of the wrapped test (exit status $status) ---"
  cat "$log"
  echo "--- end of output ---"
}

if ((status == 0)); then
  echo "expect_failure_test: FAIL: the wrapped test passed, but it must fail" >&2
  show_output
  exit 1
fi

if ((want_status != 0 && status != want_status)); then
  echo "expect_failure_test: FAIL: the wrapped test exited with status $status," \
    "but it must exit with status $want_status" >&2
  show_output
  exit 1
fi

match=0
if ((first_line_only)); then
  # No output has no first line, so it must not match, not even '^$'. The
  # check needs the log's size because an empty log would otherwise read as an
  # empty first line. The line goes straight into grep, not through a shell
  # variable, which would drop NUL bytes ("ri\0ght" would match '^right$');
  # -a reads a line with a NUL as text instead of as a binary file.
  if [[ -s $log ]]; then
    head -n 1 "$log" | grep -Eaq -- "$pattern" || match=$?
  else
    match=1
  fi
else
  grep -Eq -- "$pattern" "$log" || match=$?
fi
case $match in
0)
  echo "expect_failure_test: ok: the wrapped test failed (exit status $status)" \
    "with output matching '$pattern'"
  show_output
  exit 0
  ;;
1)
  echo "expect_failure_test: FAIL: the wrapped test failed (exit status $status)," \
    "but its output does not match '$pattern'" >&2
  show_output
  exit 1
  ;;
*)
  echo "expect_failure_test: FAIL: '$pattern' is not a valid extended regular" \
    "expression (grep exited $match)" >&2
  exit 1
  ;;
esac
