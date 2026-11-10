#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Proves that mutation reports rerun along Bazel's dependency graph: in a
# copy of the workspace consumer, an edit to a unit reruns that unit's
# mutmut report and its dependents' and leaves the others cached, and a
# change set reruns only the units whose slice of it changed. app depends
# on core; cli depends on neither. A report Bazel reran is rewritten,
# a cached one is not, so the check is whether each report is newer than a
# marker written before the build. Runs Bazel itself, so it is a CI step,
# not a test: `python/e2e/incremental.sh`.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
rules=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
ws="$work/ws"
bazel() { bazelisk --output_base="$work/out" "$@"; }
cleanup() {
  bazel shutdown >/dev/null 2>&1 || true
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir "$ws"
(cd "$here/workspace" && tar -cf - --exclude='./.bazel-*' --exclude='./bazel-*' .) | (cd "$ws" && tar -xf -)
sed -i.orig \
  -e "s|path = \"../../..\"|path = \"$rules\"|" \
  -e "s|path = \"../..\"|path = \"$rules/python\"|" \
  "$ws/MODULE.bazel"
rm "$ws/MODULE.bazel.orig"
sed -i.orig "s|%workspace%/../../../preset.bazelrc|$rules/preset.bazelrc|" "$ws/.bazelrc"
rm "$ws/.bazelrc.orig"
cd "$ws"

units=(core app cli)
target() {
  case $1 in
  cli) echo //:mutmut_test ;;
  *) echo "//:mutmut_$1_test" ;;
  esac
}
# The convenience link follows the last build's configuration, as `bazel info
# bazel-bin` would for the flags that build used.
report() {
  case $1 in
  cli) echo .bazel-bin/mutmut_test.report.report ;;
  *) echo ".bazel-bin/mutmut_$1_test.report.report" ;;
  esac
}
targets=()
for unit in "${units[@]}"; do
  targets+=("$(target "$unit")")
done

bazel test "${targets[@]}" >/dev/null 2>&1 || bazel test "${targets[@]}"

failed=0
# rebuild LABEL RERUN... [-- BAZEL_FLAG...]: rebuild, and check that exactly
# the RERUN units' reports were rewritten since the marker.
rebuild() {
  local label=$1
  shift
  local rerun=() flags=()
  while (($# > 0)) && [[ $1 != -- ]]; do
    rerun+=("$1")
    shift
  done
  if (($# > 0)); then
    shift
    flags=("$@")
  fi
  bazel test "${flags[@]}" "${targets[@]}" >/dev/null 2>&1 || bazel test "${flags[@]}" "${targets[@]}"
  for unit in "${units[@]}"; do
    local want=cached got=cached
    if [[ " ${rerun[*]} " == *" $unit "* ]]; then
      want=rerun
    fi
    local path newer
    path=$(report "$unit")
    newer=$(find "$path" -newer "$work/marker")
    if [[ -n $newer ]]; then
      got=rerun
    fi
    if [[ $want == "$got" ]]; then
      echo "incremental: $label: $unit $got"
    else
      echo "incremental: FAIL: $label: $unit $got, expected $want" >&2
      failed=1
    fi
  done
}

mark() {
  touch "$work/marker"
  sleep 1
}

# edit FILE RERUN...: append a comment to FILE and rebuild.
edit() {
  local file=$1
  shift
  mark
  echo "# edited by incremental.sh" >>"$file"
  rebuild "$file" "$@"
}

# changes BASE ENTRIES RERUN...: write a change set (ENTRIES is its files
# lines) and rebuild with it set as quality's change set flag.
changes() {
  local base=$1 entries=$2
  shift 2
  mark
  mkdir -p .mutation
  printf '{\n  "version": 1,\n  "base": "%s",\n  "files": {\n%s\n  }\n}\n' "$base" "$entries" >.mutation/changes.json
  rebuild "change set $base" "$@" -- --@tbhb_rules//quality:changes=//:mutation_changes
}

edit core/src/corepkg/__init__.py core app
edit app/src/apppkg/__init__.py app
edit cli/src/clipkg/layout.py cli
edit weak/src/weakpkg/__init__.py

# Diff mode: each report action takes only its unit's slice of the change
# set. Setting one gives every unit a slice, so all rerun; then a change set
# that differs in its base and in app's entries alone reruns only app, and
# core's and cli's slices, unchanged, keep them cached.
changes 1111111111111111111111111111111111111111 \
  '    "core/src/corepkg/__init__.py": [[9, 9]]' core app cli
changes 2222222222222222222222222222222222222222 \
  '    "app/src/apppkg/__init__.py": [[11, 11]],
    "core/src/corepkg/__init__.py": [[9, 9]]' app

# A worker override enters the report action's cache key. Changing it
# reruns every unit; repeating the same override leaves them cached.
for cap in 2 3; do
  flag="--@tbhb_rules_python//:mutmut_max_children=$cap"
  mark
  rebuild "worker cap $cap" "${units[@]}" -- "$flag"
  for unit in "${units[@]}"; do
    path=$(report "$unit")
    grep -Fx "mutmut_report: --max-children $cap (set by --mutmut_max_children)" "${path%.report}.log"
  done
  mark
  rebuild "worker cap $cap cached" -- "$flag"
done

if ((failed)); then
  exit 1
fi
echo "incremental: ok"
