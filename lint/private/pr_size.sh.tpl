#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# cspell:ignore textconv

set -euo pipefail
scc="$PWD/@@SCC@@"
git="$PWD/@@GIT@@"
policy="$PWD/@@POLICY@@"
if (($# != 2)); then
  echo 'usage: pr_size_count BASE HEAD' >&2
  exit 2
fi
if [[ ! -x $scc ]]; then
  echo 'pr_size_count: scc missing or not executable' >&2
  exit 1
fi
cd "${BUILD_WORKSPACE_DIRECTORY:?run with bazel run}"
if [[ ${PR_AUTHOR:-} == 'tbhb-dev-renovate[bot]' ]]; then
  echo '{"code_lines": 0, "code_limit": 400, "raw_lines": 0, "raw_limit": 1500, "failed": null}'
  exit 0
fi
base=$1 head=$2
# A repository's baseline PR is exempt. It is the lowest-numbered open PR into
# main while main's live tip is still the single root commit that
# `tbhbdev repo bootstrap` creates, and that commit carries the bootstrap
# trailer as a full line, both in the raw message and in the parsed trailers.
# MAIN_TIP and LOWEST_OPEN_PR are live API reads the workflow passes in. Any
# missing input (no tip, no PR numbers, a shallow clone) means no
# exemption. PR numbers only grow, so the lowest open PR cannot be displaced,
# and a PR checked while not lowest gets the limit. A run after main moves
# sees a different tip and applies the limit.
bootstrap_line='^Repo-bootstrap: tbhbdev [^[:space:]]+$'
base_commit=$("$git" rev-parse --verify --quiet "$base^{commit}") || base_commit=
if [[ -n $base_commit && -n ${PR_NUMBER:-} && ${PR_NUMBER:-} == "${LOWEST_OPEN_PR:-}" &&
  $("$git" rev-parse --is-shallow-repository) == false &&
  $("$git" rev-list --count "$base_commit") == 1 &&
  ${MAIN_TIP:-} == "$base_commit" ]]; then
  message=$("$git" log -1 --format=%B "$base_commit")
  trailers=$("$git" interpret-trailers --parse <<<"$message")
  if grep -Eqx -- "$bootstrap_line" <<<"$message" && grep -Eqx -- "$bootstrap_line" <<<"$trailers"; then
    echo '{"code_lines": 0, "code_limit": 400, "raw_lines": 0, "raw_limit": 1500, "failed": null}'
    exit 0
  fi
fi
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
failed=null
if ((code > 400)); then
  failed='"code"'
elif ((raw > 1500)); then
  failed='"raw"'
fi
printf '{"code_lines": %d, "code_limit": 400, "raw_lines": %d, "raw_limit": 1500, "failed": %s}\n' "$code" "$raw" "$failed"
