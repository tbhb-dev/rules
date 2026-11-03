#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs one tool over a real copy of the declared files. Generated from
# tree_check.sh.tpl by the tree_check rule; the @@NAME@@ markers are filled
# in at analysis time.
#
# Why a copy: runfiles may be symlinks, and some tools skip symlinks, so a
# scan of the runfiles tree can pass while checking nothing. Some tools also
# write caches next to their config or inputs. The copy dereferences every
# link, keeps the repository-relative layout so configs that name other files
# still resolve, and is the only tree the tool can write to.

set -euo pipefail

runfiles=$PWD
tool="$runfiles/@@TOOL@@"
manifest="$runfiles/@@MANIFEST@@"
cache_manifest="$runfiles/@@CACHE_MANIFEST@@"
git_root=@@GIT_ROOT@@
min_files=@@MIN_FILES@@
output_guard=@@OUTPUT_GUARD@@
strip_prefix=@@STRIP_PREFIX@@

tree="$TEST_TMPDIR/tree"
bin="$TEST_TMPDIR/bin"
log="$TEST_TMPDIR/tool.log"
mkdir -p "$tree" "$bin"

# Tools that the main tool looks up on PATH (actionlint runs shellcheck).
path_tools=(@@PATH_TOOLS@@)
# The ${a[@]+...} form keeps an empty array safe under set -u in bash 3.2.
for path_tool in ${path_tools[@]+"${path_tools[@]}"}; do
  ln -s "$runfiles/$path_tool" "$bin/$(basename "$path_tool")"
done
export PATH="$bin:$PATH"

# -h dereferences symlinks in both GNU and BSD tar. The manifest lists one
# path per line, relative to strip_prefix (or to the repository root), which
# is also where it sits in the runfiles because the rule only accepts files
# from the main repository.
if [[ -s $manifest ]]; then
  tar -C "$runfiles/$strip_prefix" -chf - -T "$manifest" | tar -C "$tree" -xf -
  chmod -R u+w "$tree"
fi

files=$(find "$tree" -type f | wc -l | tr -d ' ')
bytes=$(find "$tree" -type f -exec cat {} + | wc -c | tr -d ' ')
echo "tree_check: scan tree holds $files files, $bytes bytes"
if ((files < min_files || bytes == 0)); then
  echo "tree_check: FAIL: expected at least $min_files non-empty files; the" \
    "check would have scanned almost nothing, which proves nothing" >&2
  exit 1
fi

# A private cache, seeded with the files the rule pins, so a tool that
# would fetch them reads them offline and never sees the user's own cache.
export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
mkdir -p "$XDG_CACHE_HOME"
while IFS=$'\t' read -r src dest; do
  mkdir -p "$(dirname "$XDG_CACHE_HOME/$dest")"
  cp -L "$runfiles/$src" "$XDG_CACHE_HOME/$dest"
done <"$cache_manifest"

if [[ -n $git_root ]]; then
  mkdir -p "$tree/.git"
fi

cd "$tree"
status=0
"$tool" @@TOOL_ARGS@@ "$@" >"$log" 2>&1 || status=$?
cat "$log"

if [[ -n $output_guard ]] && ! grep -Eq -- "$output_guard" "$log"; then
  echo "tree_check: FAIL: tool output did not match the guard" \
    "'$output_guard', so the tool may have scanned nothing" >&2
  exit 1
fi
exit "$status"
