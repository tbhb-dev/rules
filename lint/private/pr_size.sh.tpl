#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore textconv

set -euo pipefail
scc="$PWD/@@SCC@@"
git="$PWD/@@GIT@@"
policy="$PWD/@@POLICY@@"
cd "${BUILD_WORKSPACE_DIRECTORY:?run with bazel run}"
if [[ ${PR_AUTHOR:-} == 'tbhb-dev-renovate[bot]' ]]; then
  echo 'pr_size: Renovate exempt; code=0/400 raw=0/1500'
  exit 0
fi
base=$1 head=$2
work=$(mktemp -d "${TMPDIR:-/tmp}/pr-size.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/full" "$work/added"
paths=() raw_only=() prose=()
section=paths
while IFS= read -r line; do
  case $line in
  '' | '#'*) continue ;;
  '[raw-only]') section=languages ;;
  '[prose]') section=prose ;;
  *)
    case $section in
    paths) paths+=("$line") ;;
    prose) prose+=("$line") ;;
    languages) raw_only+=("$line") ;;
    esac
    ;;
  esac
done <"$policy"
if [[ -f .github/pr-size-exempt.txt ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] || paths+=("$line")
  done <.github/pr-size-exempt.txt
fi
scan() {
  "$scc" --no-config --no-gitignore --no-ignore --no-scc-ignore --count-ignore \
    --exclude-file '' --count-as-pattern '*/BUILD:Bazel:Bazel' \
    --count-as-pattern '*.bazel:Bazel:Bazel' --gen --format csv "$1"
}
code=0 raw=0
"$git" diff --no-renames --diff-filter=AM --name-only -z "$base...$head" >"$work/files"
while IFS= read -r -d '' path; do
  exempt=0
  for pattern in "${paths[@]}"; do
    # shellcheck disable=SC2053 # The policy contains globs.
    if [[ $path == $pattern || /$path == $pattern || ${path##*/} == $pattern ]]; then
      exempt=1
      break
    fi
  done
  ((exempt)) && continue
  attributes=$("$git" check-attr linguist-generated linguist-vendored -- "$path")
  if awk -F': ' '$NF == "set" || $NF == "true" {found=1} END {exit !found}' <<<"$attributes"; then continue; fi
  stat=$("$git" diff --no-ext-diff --no-textconv --numstat "$base...$head" -- "$path")
  [[ $stat == -* ]] && continue
  name=${path##*/}
  "$git" show "$head:$path" >"$work/full/$name"
  full=$(scan "$work/full/$name")
  [[ $full == *'(gen)'* ]] && continue
  IFS=, read -r language _ < <(sed -n '2p' <<<"$full") || true
  for pattern in "${prose[@]}"; do
    # shellcheck disable=SC2053 # Prose language globs.
    if [[ $language == $pattern ]]; then
      exempt=1
      break
    fi
  done
  ((exempt)) && continue
  "$git" diff --no-ext-diff --no-textconv --no-renames --unified=0 "$base...$head" -- "$path" |
    awk '/^@@/ {hunk=1; next} hunk && /^\+/ {print substr($0,2)}' >"$work/added/$name"
  count=$(wc -l <"$work/added/$name")
  raw=$((raw + count))
  added=$(scan "$work/added/$name")
  IFS=, read -r language _ amount _ < <(sed -n '2p' <<<"$added") || true
  for pattern in "${raw_only[@]}"; do
    # shellcheck disable=SC2053 # Language mappings are globs too.
    if [[ $language == $pattern ]]; then
      amount=0
      break
    fi
  done
  code=$((code + ${amount:-0}))
done <"$work/files"
echo "pr_size: code=$code/400 raw=$raw/1500"
failed=()
((code > 400)) && failed+=('400 added Code lines')
((raw > 1500)) && failed+=('1500 raw added lines')
if ((${#failed[@]})); then
  echo "pr_size: FAIL: ${failed[*]}; code=$code/400 raw=$raw/1500; split into stacked PRs" >&2
  exit 1
fi
