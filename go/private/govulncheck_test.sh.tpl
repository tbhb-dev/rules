#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Scans a Go module for reachable vulnerabilities with govulncheck. Generated
# from govulncheck_test.sh.tpl by the govulncheck_test and govulncheck rules;
# the @@NAME@@ markers are filled in at analysis time.
#
# The SARIF report goes to $TEST_UNDECLARED_OUTPUTS_DIR/govulncheck.sarif
# under `bazel test`, and, under `bazel run`, to the file named by a
# --sarif=<file> argument (relative to the directory bazel was run in).

set -euo pipefail

sarif=()
if [[ -n ${TEST_UNDECLARED_OUTPUTS_DIR:-} ]]; then
  sarif=(-sarif "$TEST_UNDECLARED_OUTPUTS_DIR/govulncheck.sarif")
elif [[ ${1:-} == --sarif=* ]]; then
  file=${1#--sarif=}
  # An absolute path, POSIX or with a drive letter, is used as it is.
  if [[ $file != /* && $file != [A-Za-z]:* ]]; then
    file=${BUILD_WORKING_DIRECTORY:-.}/$file
  fi
  sarif=(-sarif "$file")
fi

# The runner's argument list, in the form [-flag value ...].
flags=(@@FLAGS@@)

exec @@RUNNER@@ -govulncheck @@GOVULNCHECK@@ "${flags[@]}" ${sarif[@]+"${sarif[@]}"}
