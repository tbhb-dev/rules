#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the swift-format of the Xcode the host selects over the sources in
# the runfiles tree. swift-format has no release binary and no registry
# module, so this is host state, not something Bazel fetched. The macro
# passes SWIFT_FORMAT_CONFIG and SWIFT_FORMAT_SOURCES (paths separated by
# spaces) in the environment.
set -euo pipefail
read -ra sources <<<"${SWIFT_FORMAT_SOURCES}"
exec xcrun swift-format lint --strict --configuration "${SWIFT_FORMAT_CONFIG}" "${sources[@]}"
