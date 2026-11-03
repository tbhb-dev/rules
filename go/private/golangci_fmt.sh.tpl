#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# golangci-lint with the Go SDK's go on PATH. Generated from
# golangci_fmt.sh.tpl by golangci_fmt_tool; the @@NAME@@ markers are filled
# in at analysis time. It runs from any working directory.

set -euo pipefail

# The runfiles root, found as launch.sh.tpl does: the script's own runfiles
# (bazel run), else the runfiles Bazel names in the environment (tests and
# the runners they start), else the script's path, which ends in @@SELF@@.
# On Windows $0 can be a C:\ path the shell cannot use, so the environment
# comes before it.
if [[ -d "$0.runfiles/_main" ]]; then
  runfiles="$0.runfiles/_main"
elif [[ -n ${RUNFILES_DIR:-} ]]; then
  runfiles="$RUNFILES_DIR/_main"
elif [[ -n ${TEST_SRCDIR:-} ]]; then
  runfiles="$TEST_SRCDIR/_main"
elif [[ $0 == *"/@@SELF@@" ]]; then
  runfiles=${0%"/@@SELF@@"}
  if [[ $runfiles != /* ]]; then
    runfiles="$(pwd -P)/$runfiles"
  fi
else
  echo "golangci_fmt: cannot find the runfiles of $0" >&2
  exit 1
fi

goroot=$(dirname "$(dirname "$runfiles/@@GO@@")")
export GOROOT=$goroot
export PATH="$goroot/bin:$PATH"
# Formatting never needs a download or another toolchain.
export GOPROXY=off
export GOTOOLCHAIN=local

exec "$runfiles/@@GOLANGCI_LINT@@" "$@"
