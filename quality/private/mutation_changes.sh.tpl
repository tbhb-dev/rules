#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Writes the change set of a diff-scoped mutation run. Generated from
# mutation_changes.sh.tpl by the mutation_changes rule; run it with
# `bazel run`, from the workspace:
#
#   mutation_changes --base REV --out FILE
#
# FILE gets {"version": 1, "base": "<sha>", "files": {path: CHANGE}}, one
# file per line, for each path changed between the merge base of REV and
# HEAD plus the working tree, repository-relative. CHANGE is "added",
# "deleted", or the changed line ranges on the new side, [[start, end], ...],
# 1-based and inclusive; a deletion-only hunk is the line after it ([n, n],
# n at least 1), and a change with no text hunks (binary, mode) is []. The
# one-file-per-line layout is part of the format: quality's slice action
# reads it line by line. Runners treat any change they can't scope by line
# (tests, config, data, added or deleted files) as a reason for a full run,
# so the format carries no more than this. Untracked files are not in the
# diff: commit or `git add -N` them first.

set -euo pipefail

export PATH="$PWD/@@GIT_DIR@@:$PATH"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
base="" out=""
while (($# > 0)); do
  case $1 in
  --base)
    base=${2:?--base needs a revision}
    shift 2
    ;;
  --out)
    out=${2:?--out needs a file}
    shift 2
    ;;
  *)
    echo "mutation_changes: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done
if [[ -z $base || -z $out ]]; then
  echo "usage: mutation_changes --base REV --out FILE" >&2
  exit 2
fi
cd "${BUILD_WORKSPACE_DIRECTORY:?run with bazel run}"
merge_base=$(git merge-base "$base" HEAD)

# The JSON is built by awk from the diff. Paths are escaped for JSON;
# git quotes unusual paths, and -c core.quotePath=false keeps UTF-8 as is.
diff=$(git -c core.quotePath=false diff -U0 --no-renames --no-ext-diff --no-color \
  --src-prefix=a/ --dst-prefix=b/ "$merge_base" --)
tmp=$(mktemp "${out}.XXXXXX")
printf '%s\n' "$diff" | awk -v base="$merge_base" '
  function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return s }
  # A header name: git C-quotes one with a quote, backslash or control
  # character, and ends one with a space in a tab.
  function header_name(s,    out, i, c) {
    sub(/\t$/, "", s)
    if (substr(s, 1, 1) != "\"") return s
    s = substr(s, 2, length(s) - 2)
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\") {
        i++
        c = substr(s, i, 1)
        if (c == "t") c = "\t"
        else if (c == "n") c = "\n"
      }
      out = out c
    }
    return out
  }
  function flush() {
    if (path == "") return
    change = added ? "\"added\"" : deleted ? "\"deleted\"" : "[" ranges "]"
    printf "%s\n    \"%s\": %s", (n++ ? "," : ""), esc(path), change
    path = ""; ranges = ""; added = 0; deleted = 0
  }
  BEGIN { printf "{\n  \"version\": 1,\n  \"base\": \"%s\",\n  \"files\": {", base }
  # The header names the file when no ---/+++ lines follow (a binary or
  # mode-only change); git quotes unusual names there, so only plain ones.
  /^diff --git / {
    flush()
    pending = 1
    header = substr($0, 14)
    half = (length(header) - 3) / 2
    if (header !~ /"/ && substr(header, half + 1, 3) == " b/" && substr(header, 1, half) == substr(header, half + 4)) {
      path = substr(header, 1, half)
    }
    next
  }
  pending && /^\+\+\+ / {
    pending = 0
    name = header_name(substr($0, 5))
    deleted = (name == "/dev/null")
    path = deleted ? old : substr(name, 3)
    next
  }
  pending && /^--- / {
    name = header_name(substr($0, 5))
    added = (name == "/dev/null")
    old = substr(name, 3)
    next
  }
  /^@@ / && !deleted {
    split($3, plus, ",")
    start = substr(plus[1], 2) + 0
    count = (2 in plus) ? plus[2] + 0 : 1
    if (count == 0) { first = start + 1; last = start + 1 } else { first = start; last = start + count - 1 }
    if (first < 1) first = 1
    if (last < first) last = first
    ranges = ranges (ranges == "" ? "" : ", ") "[" first ", " last "]"
  }
  END { flush(); printf "%s}\n}\n", (n ? "\n  " : "") }
' >"$tmp"
mv "$tmp" "$out"
echo "mutation_changes: $out: changes since $merge_base"
