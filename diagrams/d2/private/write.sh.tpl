#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Copies a package's D2 renders from the output tree beside their sources
# and removes the renders whose source is gone. Generated from
# write.sh.tpl by d2_diagrams (d2_diagrams.bzl); the @@NAME@@ markers are
# filled in at analysis time. Runs in its runfiles tree.

set -euo pipefail

if [[ -z ${BUILD_WORKSPACE_DIRECTORY:-} ]]; then
  echo "d2_diagrams: run this with bazel run, which says where the workspace is" >&2
  exit 2
fi
workspace=$BUILD_WORKSPACE_DIRECTORY
updated=0
removed=0

# put RENDER DEST: copies RENDER to DEST, a workspace path, unless it is
# already there. Outputs are read-only and executable; DEST is neither.
put() {
  local render="$PWD/$1" dest="$workspace/$2"
  if cmp -s "$render" "$dest"; then
    return
  fi
  rm -f "$dest"
  cp "$render" "$dest"
  chmod 0644 "$dest"
  echo "d2_diagrams: wrote $2"
  updated=$((updated + 1))
}

# remove DEST: deletes an orphaned render.
remove() {
  rm -f "$workspace/$1"
  echo "d2_diagrams: removed $1, whose source is gone"
  removed=$((removed + 1))
}

@@CALLS@@

echo "d2_diagrams: $updated file(s) written, $removed removed"
