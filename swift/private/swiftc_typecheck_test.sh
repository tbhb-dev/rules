#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Type-checks the sources with the Xcode the host selects, under a named
# flag set. A source that breaks the flag set fails here at run time, which
# is what lets a failing-first proof wrap it: the same breakage in a
# swift_library would fail the build instead. The macro passes
# SWIFTC_MODULE_NAME, SWIFTC_FLAGS and SWIFTC_SOURCES (each a list separated
# by spaces) in the environment. The sources are library modules, so no
# file is top-level code.
set -euo pipefail
read -ra sources <<<"${SWIFTC_SOURCES}"
read -ra flags <<<"${SWIFTC_FLAGS}"
exec xcrun swiftc -typecheck -parse-as-library -module-name "${SWIFTC_MODULE_NAME}" ${flags[@]+"${flags[@]}"} "${sources[@]}"
