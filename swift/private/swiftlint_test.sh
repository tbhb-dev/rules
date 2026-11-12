#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the Bazel-fetched SwiftLint over the sources in the runfiles tree,
# which is the working directory. It fails on any violation, warnings
# included. The macro passes its inputs in the environment, not as
# arguments, which expect_failure_test doesn't forward to a wrapped test:
# SWIFTLINT (the binary), SWIFTLINT_CONFIG and SWIFTLINT_SOURCES (paths
# separated by spaces).
set -euo pipefail
read -ra sources <<<"${SWIFTLINT_SOURCES}"
exec "${SWIFTLINT}" lint --strict --no-cache --config "${SWIFTLINT_CONFIG}" "${sources[@]}"
