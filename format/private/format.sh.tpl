#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs each formatter over the files its patterns select. Generated from
# format.sh.tpl by the format rules; the @@NAME@@ markers are filled in at
# analysis time.
#
# In a `bazel run` target the files are the workspace's tracked and
# untracked, unignored files, and `fix` rewrites them in place. In a test
# they are a dereferenced copy of the declared files, which only `check`
# reads.

set -euo pipefail

runfiles=$PWD
mode=@@MODE@@
source=@@SOURCE@@
manifest="$runfiles/@@MANIFEST@@"
strip_prefix=@@STRIP_PREFIX@@
excludes=(@@EXCLUDES@@)

# excluded FILE: whether FILE matches an `exclude` pattern (path or basename).
excluded() {
  local pattern
  for pattern in ${excludes[@]+"${excludes[@]}"}; do
    # Unquoted on purpose: the pattern is a glob.
    # shellcheck disable=SC2053
    if [[ $1 == $pattern || ${1##*/} == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

files=()
if [[ $source == copy ]]; then
  root="$TEST_TMPDIR/tree"
  mkdir -p "$root"
  if [[ -s $manifest ]]; then
    # -h dereferences symlinks in both GNU and BSD tar.
    tar -C "$runfiles/$strip_prefix" -chf - -T "$manifest" | tar -C "$root" -xf -
  fi
  cd "$root"
  listing=$(find . -type f)
  listing=$(LC_ALL=C sort <<<"$listing")
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    file=${file#./}
    excluded "$file" || files+=("$file")
  done <<<"$listing"
  if ((${#files[@]} == 0)); then
    echo "format: FAIL: no files to check, which proves nothing" >&2
    exit 1
  fi
else
  root=${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}
  # Tools that find their own files through runfiles (such as
  # @buildifier_prebuilt//:buildifier, a wrapper) resolve them relative to
  # the working directory unless RUNFILES_DIR says where the tree is.
  export RUNFILES_DIR="${RUNFILES_DIR:-$(cd "$runfiles/.." && pwd)}"
  cd "$root"
  listing=$(mktemp)
  trap 'rm -f "$listing"' EXIT
  # To a file first, so a failing git (outside a checkout) fails the run
  # rather than formatting nothing.
  git ls-files -z --cached --others --exclude-standard >"$listing"
  while IFS= read -r -d '' file; do
    # Deleted but still tracked files and symlinks are left alone.
    if [[ -f $file && ! -L $file ]] && ! excluded "$file"; then
      files+=("$file")
    fi
  done <"$listing"
fi

failed=()

# run_formatter LABEL TOOL N_PATTERNS PATTERN... N_ARGS ARG...
run_formatter() {
  local label=$1 tool="$runfiles/$2"
  shift 2
  local n=$1
  shift
  local patterns=("${@:1:n}")
  shift "$n"
  local m=$1
  shift
  local args=("${@:1:m}")

  local selected=() file pattern
  for file in ${files[@]+"${files[@]}"}; do
    for pattern in "${patterns[@]}"; do
      # Unquoted on purpose: the pattern is a glob. Matching the basename
      # too lets `BUILD.bazel` select by name at any depth.
      # shellcheck disable=SC2053
      if [[ $file == $pattern || ${file##*/} == $pattern ]]; then
        selected+=("$file")
        break
      fi
    done
  done
  if ((${#selected[@]} == 0)); then
    return 0
  fi

  echo "format: $label ($mode): ${#selected[@]} files"
  local status=0 start=0 size=200
  while ((start < ${#selected[@]})); do
    "$tool" ${args[@]+"${args[@]}"} "${selected[@]:start:size}" || status=$?
    start=$((start + size))
  done
  if ((status != 0)); then
    failed+=("$label")
  fi
}

@@CALLS@@

if ((${#failed[@]} > 0)); then
  if [[ $mode == check ]]; then
    echo "format: FAIL: not formatted according to: ${failed[*]}" >&2
  else
    echo "format: FAIL: these formatters failed: ${failed[*]}" >&2
  fi
  exit 1
fi
echo "format: ok"
