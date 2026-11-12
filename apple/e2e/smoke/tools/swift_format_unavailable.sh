#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# swift-format cannot run hermetically here, so this target fails on purpose
# instead of passing without checking anything.
cat >&2 <<'MSG'
swift-format has no hermetic source in this workspace:
  - apple/swift-format publishes no release binaries;
  - the Bazel Central Registry has no swift-format module, and the
    swift-markdown and swift-cmark modules it needs are not there either;
  - the copy in Xcode's toolchain is host state, not a Bazel-fetched binary.
See README.md for the findings.
MSG
exit 1
