#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails when a CODEOWNERS pattern matches no file in the current tree, which
# is how a rename silently orphans a rule. Run by codeowners_test at the root
# of its copy of the tree, with the pinned git first on PATH and Git's
# system and global config switched off; $1 is the CODEOWNERS path inside
# it.
#
# CODEOWNERS patterns follow .gitignore rules, so Git matches them: each
# pattern becomes an exclude file, and `git ls-files --others --ignored`
# lists the files it matches. The Git directory lives outside the tree and
# holds no commits, so every file is "other" and nothing is read from it.

set -euo pipefail

codeowners=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q --bare "$work/git"

status=0
rules=0
line_number=0
while IFS= read -r line || [[ -n $line ]]; do
  line_number=$((line_number + 1))
  pattern=${line%%#*}
  read -r pattern _ <<<"$pattern" || true
  [[ -n $pattern ]] || continue
  rules=$((rules + 1))
  printf '%s\n' "$pattern" >"$work/pattern"
  git --git-dir="$work/git" --work-tree=. ls-files --others --ignored \
    --exclude-from="$work/pattern" >"$work/matches"
  if [[ ! -s "$work/matches" ]]; then
    echo "$codeowners:$line_number: pattern '$pattern' matches no file" >&2
    status=1
  fi
done <"$codeowners"

if ((rules == 0)); then
  echo "$codeowners: no rules found, so nothing was checked" >&2
  exit 1
fi
echo "codeowners: checked $rules rules"
exit "$status"
