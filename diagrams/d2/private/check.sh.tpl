#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Checks a package's committed D2 renders. Generated from check.sh.tpl by
# d2_diagrams (d2_diagrams.bzl); the @@NAME@@ markers are filled in at
# analysis time. Runs in its runfiles tree, with the fresh SVGs and the
# manifests of the committed files built beside the committed files.

set -euo pipefail

problems=0

problem() {
  echo "$1"
  problems=$((problems + 1))
}

# missing RENDER
missing() {
  problem "missing: $1"
}

# svg FRESH COMMITTED SRC_NAME SVG_NAME
svg() {
  cmp -s "$PWD/$1" "$PWD/$2" ||
    problem "stale: $4 differs from a fresh render of $3"
}

# manifest COMPUTED COMMITTED NAME: COMPUTED holds the hashes of the
# committed files.
manifest() {
  local computed="$PWD/$1" committed="$PWD/$2" line reported=0
  if cmp -s "$computed" "$committed"; then
    return
  fi
  while IFS= read -r line; do
    if ! grep -Fxq -- "$line" "$committed"; then
      problem "mismatch: $3 does not hold the hash of ${line#*  }"
      reported=1
    fi
  done <"$computed"
  if ((reported == 0)); then
    problem "mismatch: $3 is not the manifest its renders would have; expected:"
    cat "$computed"
  fi
}

# orphan RENDER SRC
orphan() {
  problem "orphan: $1 has no source ($2 is not among the srcs)"
}

@@CALLS@@

if ((problems)); then
  echo "d2_diagrams: $problems problem(s) in @@PACKAGE@@; run '@@RUN@@' to render again"
  exit 1
fi
echo "d2_diagrams: @@COUNT@@ diagram(s) in @@PACKAGE@@ are up to date"
