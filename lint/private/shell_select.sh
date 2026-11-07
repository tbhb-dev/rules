#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs a shell tool over the shell scripts in the current tree. The lint
# rules for shellcheck and shfmt run it at the root of their copy of the
# tree.
#
# Usage: shell_select.sh [--allow-empty] [--exclude PATTERN]... -- TOOL [ARG]...
#
# A file is a script when its name ends in .sh, .bash or .bats, or when its
# first line is a sh, bash, dash, ksh or bats shebang, so extensionless
# scripts and templates are covered too. PATTERN is a bash [[ == ]] pattern
# matched against the tree-relative path. The scripts are appended to the
# tool's arguments; finding none fails, since a check of nothing proves
# nothing, unless --allow-empty is given.

set -euo pipefail

shebang='^#![[:space:]]*(/usr/bin/env[[:space:]]+(-S[[:space:]]+)?)?([^[:space:]]*/)?(sh|bash|dash|ksh|bats)([[:space:]]|$)'

allow_empty=false
excludes=()
while (($#)); do
  case $1 in
  --allow-empty)
    allow_empty=true
    shift
    ;;
  --exclude)
    excludes+=("$2")
    shift 2
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "shell_select: unexpected argument '$1'" >&2
    exit 2
    ;;
  esac
done
if (($# == 0)); then
  echo "shell_select: no tool given" >&2
  exit 2
fi

listing=${TEST_TMPDIR:-${TMPDIR:-/tmp}}/shell_select.files
find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z >"$listing"
scripts=()
while IFS= read -r -d '' file; do
  file=${file#./}
  for pattern in ${excludes[@]+"${excludes[@]}"}; do
    # shellcheck disable=SC2053 # The pattern is a glob on purpose.
    [[ $file == $pattern ]] && continue 2
  done
  if [[ $file == *.sh || $file == *.bash || $file == *.bats ]] ||
    head -n 1 -- "$file" | grep -Eq -- "$shebang"; then
    scripts+=("$file")
  fi
done <"$listing"

if [[ -z ${scripts[0]+set} ]]; then
  if $allow_empty; then
    echo "shell_select: no shell scripts found; allow_empty is set, so nothing was checked"
    exit 0
  fi
  echo "shell_select: no shell scripts found, so nothing was checked" >&2
  exit 1
fi
echo "shell_select: ${#scripts[@]} scripts: ${scripts[*]}"
exec "$@" "${scripts[@]}"
