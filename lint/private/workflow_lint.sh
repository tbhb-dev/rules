#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Checks GitHub Actions YAML files for three things:
#   1. a `uses:` ref that is not a full 40-hex commit SHA,
#   2. a floating runner label (ubuntu-latest, macos-latest, windows-latest),
#   3. a `self-hosted` label, unless --private says the repository is private.
#
# Usage: workflow_lint.sh [--private] [PATH...]
# PATH is a file or directory, default `.github`. Every *.yml and *.yaml file
# below it is scanned. Comments are ignored.
#
# Local actions (`./...`) are skipped because they live in the same commit as
# the caller, so they have no ref to pin. `docker://` references are skipped
# because their pin is an image digest, not a commit SHA.

set -euo pipefail

private=
if [[ ${1-} == --private ]]; then
  private=1
  shift
fi
paths=("$@")
if ((${#paths[@]} == 0)); then
  paths=(.github)
fi

problems=0
scanned=0

report() {
  echo "workflow_lint: FAIL: $1:$2: $3" >&2
  problems=$((problems + 1))
}

files=$(find "${paths[@]}" -type f \( -name '*.yml' -o -name '*.yaml' \))
files=$(sort <<<"$files")

while IFS= read -r file; do
  [[ -n $file ]] || continue
  scanned=$((scanned + 1))
  # Blank out comments so line numbers stay true.
  text=$(sed -E 's/(^|[[:space:]])#.*$//' "$file")

  while IFS=: read -r line rest; do
    [[ -n $line ]] || continue
    value=${rest#*uses:}
    value=${value//[\"\' ]/}
    case $value in
    ./* | docker://*) continue ;;
    esac
    ref=
    if [[ $value == *@* ]]; then
      ref=${value##*@}
    fi
    if [[ ! $ref =~ ^[0-9a-f]{40}$ ]]; then
      report "$file" "$line" "uses '$value' is not pinned to a full commit SHA. Replace the ref with the 40-character commit SHA and keep the version in a trailing comment."
    fi
  done < <(grep -nE '^[[:space:]-]*uses:' <<<"$text" || true)

  while IFS=: read -r line rest; do
    [[ -n $line ]] || continue
    label=$(grep -oE '(ubuntu|macos|windows)-latest' <<<"$rest" | head -n 1)
    report "$file" "$line" "runner label '$label' floats. Name a fixed image such as ubuntu-26.04."
  done < <(grep -nE '(ubuntu|macos|windows)-latest' <<<"$text" || true)

  if [[ -z $private ]]; then
    while IFS=: read -r line _; do
      [[ -n $line ]] || continue
      report "$file" "$line" "the self-hosted label is allowed only in a private repository. Use a GitHub-hosted runner, or pass --private if the repository is private."
    done < <(grep -nE '(^|[^A-Za-z0-9_-])self-hosted([^A-Za-z0-9_-]|$)' <<<"$text" || true)
  fi
done <<<"$files"

echo "workflow_lint: scanned $scanned files, found $problems problems"
if ((scanned == 0)); then
  echo "workflow_lint: FAIL: no YAML files under ${paths[*]}, so nothing was checked" >&2
  exit 1
fi
((problems == 0))
