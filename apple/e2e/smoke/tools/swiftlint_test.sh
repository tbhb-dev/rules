#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the Bazel-fetched SwiftLint (the first argument) over the sources in
# the runfiles tree, which is the working directory. It fails on any
# violation, warnings included.
set -euo pipefail
swiftlint=$1
exec "${swiftlint}" lint --strict --no-cache --config .swiftlint.yml
