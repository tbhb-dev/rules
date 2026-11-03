#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Checks the repository layout. Generated from repo_layout.sh.tpl; the
# @@NAME@@ markers are filled in at analysis time.
#
# The manifest lists each file as `path<TAB>runfile`, the path relative to
# the layout's root. The rules file holds `top<TAB>dir`,
# `script<TAB>dir<TAB>kind` and `subdir<TAB>dir<TAB>name` lines.

set -euo pipefail

manifest=@@MANIFEST@@
rules=@@RULES@@
shebang='#!/usr/bin/env -S uv run --script'

top=()
script_dirs=()
subdirs=()
while IFS=$'\t' read -r kind a b; do
  case $kind in
  top) top+=("$a") ;;
  script) script_dirs+=("$a") ;;
  subdir) subdirs+=("$a/$b") ;;
  esac
done <"$rules"

# member WORD LIST...: whether WORD is one of LIST.
member() {
  local word=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$word" ]] && return 0
  done
  return 1
}

problems=()
unknown=()
count=0
while IFS=$'\t' read -r path runfile; do
  count=$((count + 1))
  [[ $path == */* ]] || continue
  dir=${path%%/*}
  if ! member "$dir" ${top[@]+"${top[@]}"}; then
    member "$dir" ${unknown[@]+"${unknown[@]}"} || unknown+=("$dir")
    continue
  fi
  member "$dir" ${script_dirs[@]+"${script_dirs[@]}"} || continue
  rest=${path#*/}
  if [[ $rest == */* ]]; then
    if ! member "$dir/${rest%%/*}" ${subdirs[@]+"${subdirs[@]}"}; then
      problems+=("$path: $dir/ holds no subdirectory ${rest%%/*}/")
    fi
    continue
  fi
  if [[ $rest == *.* ]]; then
    problems+=("$path: $dir/ scripts carry no file extension")
    continue
  fi
  first=$(head -n 1 "$runfile")
  if [[ $first != "$shebang" ]]; then
    problems+=("$path: must start with '$shebang'")
  elif ! tail -n +2 "$runfile" | grep -qxF '# /// script'; then
    problems+=("$path: must declare inline script metadata (# /// script)")
  fi
done <"$manifest"

if ((count == 0)); then
  echo "repo_layout: FAIL: no files to check, which proves nothing" >&2
  exit 1
fi

while IFS= read -r dir; do
  [[ -n $dir ]] && problems+=("$dir/: top-level directory is not in the layout")
done < <(printf '%s\n' ${unknown[@]+"${unknown[@]}"} | LC_ALL=C sort)

if ((${#problems[@]} > 0)); then
  printf '%s\n' "${problems[@]}"
  echo "repo_layout: FAIL: ${#problems[@]} problems in $count files" >&2
  exit 1
fi
echo "repo_layout: ok, $count files conform"
