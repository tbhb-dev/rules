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

# error MESSAGE: a comparison that could not run. It stops the check at
# once with a message of its own, so a missing tool or an unreadable file
# never reads as a stale render or a mismatched manifest.
error() {
  echo "d2_diagrams: error: $1" >&2
  exit 2
}

# digest FILE: sets hash to FILE's SHA-256, read from standard input as
# render.sh reads it. Not cmp(1): Windows CI's MSYS2 has no diffutils.
# macOS has shasum but not always sha256sum.
digest() {
  local line
  if command -v sha256sum >/dev/null; then
    line=$(sha256sum <"$1") || error "cannot hash $1 with sha256sum"
  elif command -v shasum >/dev/null; then
    line=$(shasum -a 256 <"$1") || error "cannot hash $1 with shasum"
  else
    error "cannot hash $1: neither sha256sum nor shasum is on PATH"
  fi
  hash=${line%% *}
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || error "cannot hash $1: the hash tool printed '$line'"
}

# missing RENDER
missing() {
  problem "missing: $1"
}

# svg FRESH COMMITTED SRC_NAME SVG_NAME: the message carries both hashes,
# which only a comparison that ran can print.
svg() {
  local fresh
  digest "$PWD/$1"
  fresh=$hash
  digest "$PWD/$2"
  if [[ $hash != "$fresh" ]]; then
    problem "stale: $4 differs from a fresh render of $3 (sha256 $hash, fresh render $fresh)"
  fi
}

# manifest COMPUTED COMMITTED NAME: COMPUTED holds the hashes of the
# committed files.
manifest() {
  local computed="$PWD/$1" committed="$PWD/$2" line found want reported=0
  digest "$computed"
  want=$hash
  digest "$committed"
  if [[ $hash == "$want" ]]; then
    return
  fi
  while IFS= read -r line; do
    [[ $line =~ ^[0-9a-f]{64}\ \ . ]] || error "cannot read $1: '$line' is not a manifest line"
    found=0
    grep -Fxq -- "$line" "$committed" || found=$?
    case $found in
    0) ;;
    1)
      problem "mismatch: $3 does not hold the hash of ${line#*  } (sha256 ${line%%  *})"
      reported=1
      ;;
    *) error "cannot search $2 for the hash of ${line#*  } (grep exited $found)" ;;
    esac
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
