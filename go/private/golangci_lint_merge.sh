#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Merges golangci-lint aspect reports into one sorted list of findings.
#
# Usage: golangci_lint_merge.sh MANIFEST
#
# MANIFEST lists report files (<name>.txt), one per line; each has a
# <name>.covers next to it: `variant=lib` or
# `variant=test`, then the source files the report covers. golangci-lint
# lints a package that has tests only as its test variant, so findings in a
# file that a test variant covers are taken from test variants only; a
# library report's findings there are dropped (a function used only by
# tests is not unused).

set -euo pipefail

manifest=$1

tested=$(mktemp)
trap 'rm -f "$tested"' EXIT

# variant REPORT: the first line of the report's covers file.
variant() {
  local line
  IFS= read -r line <"${1%.txt}.covers"
  echo "$line"
}

while IFS= read -r report; do
  kind=$(variant "$report")
  if [[ $kind == variant=test ]]; then
    tail -n +2 "${report%.txt}.covers" >>"$tested"
  fi
done <"$manifest"

while IFS= read -r report; do
  kind=$(variant "$report")
  if [[ $kind == variant=test ]]; then
    cat "$report"
  else
    # A finding is `path:line:col: text`; keep it unless a test variant
    # covers its path.
    awk -F: -v tested="$tested" '
      BEGIN { while ((getline line <tested) > 0) covered[line] = 1 }
      !($1 in covered)
    ' "$report"
  fi
done <"$manifest" | LC_ALL=C sort -u
