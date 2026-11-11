#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
ulimit -c 0

uv="$TEST_SRCDIR/$UV_RLOCATIONPATH"
fixture="$(dirname "$TEST_SRCDIR/$FIXTURE_RLOCATIONPATH")"
project="$TEST_TMPDIR/project"
mkdir -p "$project"
cp "$fixture/pyproject.toml" "$fixture/uv.lock" "$project/"
cd "$project"

# An empty cache and --offline make lock reuse independent of PyPI.
export UV_CACHE_DIR="$TEST_TMPDIR/cache"
export UV_PYTHON_DOWNLOADS=never
unset UV_NO_CONFIG UV_EXCLUDE_NEWER UV_EXCLUDE_NEWER_PACKAGE

grep -q '^exclude-newer-span = "P5D"$' uv.lock

# The fixture was locked at the first timestamp. Cross a day, a month and
# a year with uv's own clock override, not the system clock.
for timestamp in 2024-05-01T00:00:00Z 2024-05-02T00:00:00Z 2024-06-01T00:00:00Z 2025-05-01T00:00:00Z; do
  export UV_INTERNAL__TEST_CURRENT_TIMESTAMP="$timestamp"
  "$uv" lock --check --offline
  cmp "$fixture/uv.lock" uv.lock
  "$uv" lock --offline
  cmp "$fixture/uv.lock" uv.lock
done

# Prove this binary honors the clock override: an invalid clock must be
# rejected by the relative-time parser, rather than silently ignored.
if UV_INTERNAL__TEST_CURRENT_TIMESTAMP=invalid "$uv" lock --check --offline >clock.log 2>&1; then
  echo "uv ignored its clock override" >&2
  exit 1
fi
grep -q 'UV_INTERNAL__TEST_CURRENT_TIMESTAMP must be a valid RFC 3339 timestamp' clock.log
cmp "$fixture/uv.lock" uv.lock

# An actual span change must trigger resolution, fail offline with the
# empty cache, and leave the lock alone.
if "$uv" lock --check --offline --exclude-newer '6 days' >span.log 2>&1; then
  echo "uv accepted a changed cooldown span" >&2
  exit 1
fi
grep -q 'change of exclude newer span from .*P5D.* to .*P6D' span.log
cmp "$fixture/uv.lock" uv.lock
echo "PASS: later clocks preserve the lock; a changed span fails --check"
