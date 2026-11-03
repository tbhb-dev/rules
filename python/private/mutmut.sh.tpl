#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The mutmut_report action: copies the declared files into a scratch tree at
# their repository-relative paths, then runs mutmut in it through the
# environment's launcher. Generated from mutmut.sh.tpl by mutmut_report;
# the @@NAME@@ markers are filled in at analysis time.

set -euo pipefail

execroot=$PWD
launcher="$execroot/@@LAUNCHER@@"
report="$execroot/@@REPORT@@"
changes=@@CHANGES@@
log="$execroot/@@LOG@@"
manifest="$execroot/@@MANIFEST@@"

tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT
# Each manifest line is "<exec path>\t<tree path>". Copies, not links:
# mutmut writes beside the sources and must not reach the real tree.
while IFS=$'\t' read -r src dest; do
  mkdir -p "$tree/$(dirname "$dest")"
  cp -L "$execroot/$src" "$tree/$dest"
done <"$manifest"
chmod -R u+w "$tree"

cd "$tree"
export HOME="$tree/.home"
mkdir -p "$HOME"
# With no change set the run is full; with one, the runner scopes it.
if [[ -n $changes ]]; then
  "$launcher" "$report" "$log" "$execroot/$changes" "@@CHDIR@@"
else
  "$launcher" "$report" "$log"
fi
