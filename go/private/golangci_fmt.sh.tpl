#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# golangci-lint with the Go SDK's go on PATH. Generated from
# golangci_fmt.sh.tpl by golangci_fmt_tool; the @@NAME@@ markers are filled
# in at analysis time. It runs from any working directory and finds its
# runfiles from its own path, which ends in @@SELF@@.

set -euo pipefail

self=$0
if [[ $self != /* ]]; then
  self="$PWD/$self"
fi
runfiles=${self%/@@SELF@@}
if [[ $runfiles == "$self" ]]; then
  echo "golangci_fmt: cannot find the runfiles of $self" >&2
  exit 1
fi

goroot=$(dirname "$(dirname "$runfiles/@@GO@@")")
export GOROOT=$goroot
export PATH="$goroot/bin:$PATH"
# Formatting never needs a download or another toolchain.
export GOPROXY=off
export GOTOOLCHAIN=local

exec "$runfiles/@@GOLANGCI_LINT@@" "$@"
