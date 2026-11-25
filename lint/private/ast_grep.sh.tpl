#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

runfiles=$PWD
tool="$runfiles/"@@TOOL@@
sources="$runfiles/"@@SOURCES@@
selection="$runfiles/"@@MANIFEST@@
configs=(@@CONFIGS@@)

if (($# != 0)) && [[ $# != 2 || $1 != --changed ]]; then
  echo 'usage: ast_grep_lint [--changed BASE]' >&2
  exit 2
fi

work=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/ast-grep.XXXXXX")
trap 'rm -rf "$work"' EXIT

if (($#)); then
  export PATH="$runfiles/"@@GIT_DIR@@":$PATH"
  base=$("$runfiles/"@@MERGE_BASE@@ --ref "$2" HEAD)
  git -C "$BUILD_WORKSPACE_DIRECTORY" diff --name-only -z --no-renames --no-ext-diff --diff-filter=d "$base" -- >"$work/changed"
  selection="$work/selected"
  while IFS= read -r -d '' path; do
    if [[ -f $sources/$path ]]; then
      printf '%s\0' "$path"
    fi
  done <"$work/changed" >"$selection"
fi

if [[ ! -s $selection ]]; then
  echo 'ast-grep: no declared sources to scan'
  exit 0
fi

# Dereference runfiles links and preserve paths for rule file globs.
mkdir "$work/tree"
tar -C "$sources" --null -chf - -T "$selection" | tar -C "$work/tree" -xf -
cd "$work/tree"
status=0
for config in "${configs[@]}"; do
  # Short diagnostics go to stdout, including findings below error severity.
  # A suppression may belong to a rule in another config scanned by this loop.
  "$tool" scan --config "$runfiles/$config" --report-style short --color never --off=unused-suppression \
    --no-ignore hidden --no-ignore dot --no-ignore exclude --no-ignore global --no-ignore vcs . \
    >"$work/diagnostics" || status=$?
  if [[ -s $work/diagnostics ]]; then
    cat "$work/diagnostics"
    ((status != 0)) || status=1
  fi
done
exit "$status"
