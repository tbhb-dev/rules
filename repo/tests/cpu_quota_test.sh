#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# setup-bazel-ci's cpu_quota.sh turns a cgroup CPU quota into a CPU count.
# The test feeds it fake cgroup files.
#
# SCRIPT_RLOCATIONPATH is the script's runfiles path.

set -euo pipefail

script=${TEST_SRCDIR:?}/${SCRIPT_RLOCATIONPATH:?}
dir=${TEST_TMPDIR:?}

failures=0

# expect WANT NAME ARG...: the script's output for ARG... must be WANT, with
# "" for no output.
expect() {
  local want=$1 name=$2 got
  shift 2
  got=$(bash "$script" "$@")
  if [[ $got != "$want" ]]; then
    echo "FAIL: $name: want '$want', got '$got'" >&2
    failures=$((failures + 1))
  fi
}

# fake NAME CONTENT: writes a fake cgroup file at $dir/NAME.
fake() {
  printf '%s\n' "$2" >"$dir/$1"
}

fake a '200000 100000'
expect 2 "two CPUs" "$dir/a"
fake b '150000 100000'
expect 2 "rounds up" "$dir/b"
fake c '50000 100000'
expect 1 "under one CPU" "$dir/c"
fake d '0 100000'
expect 1 "zero quota" "$dir/d"
fake e 'max 100000'
expect "" "no quota" "$dir/e"
expect "" "missing file" "$dir/missing" "$dir/missing" "$dir/missing"
fake f '900000000 100000'
expect "" "quota not below the host's CPUs" "$dir/f"
fake g 'lots of CPUs'
expect "" "garbage" "$dir/g"
fake h ''
expect "" "empty file" "$dir/h"
fake i '200000 0'
expect "" "zero period" "$dir/i"
fake j '-1 100000'
expect "" "negative quota" "$dir/j"
fake k '99999999999999999999 100000'
expect "" "huge numbers" "$dir/k"

# cgroup v1: cpu.max is absent.
fake q1 200000
fake p1 100000
expect 2 "v1 two CPUs" "$dir/missing" "$dir/q1" "$dir/p1"
fake q2 -1
fake p2 100000
expect "" "v1 no quota" "$dir/missing" "$dir/q2" "$dir/p2"
fake q3 200000
expect "" "v1 missing period" "$dir/missing" "$dir/q3" "$dir/missing"
# cpu.max wins over v1 files.
fake m '100000 100000'
fake q4 300000
fake p4 100000
expect 1 "v2 over v1" "$dir/m" "$dir/q4" "$dir/p4"

((failures == 0)) || exit 1
echo "cpu_quota.sh: all cases passed"
