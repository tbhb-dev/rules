#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Use tracked sources, including nested modules outside the root Bazel graph.
# Local execution preserves the source symlink. Disable caching because Git's
# index and files outside the Bazel graph can change between runs.
set -euo pipefail

if [[ -n ${FIXTURE_RLOCATIONPATH:-} ]]; then
  files=("${TEST_SRCDIR:?}/$FIXTURE_RLOCATIONPATH")
elif (($#)); then
  files=("$@")
else
  source_path=${BASH_SOURCE[0]}
  while [[ -L $source_path ]]; do
    source_dir=$(cd "$(dirname "$source_path")" && pwd)
    source_path=$(readlink "$source_path")
    [[ $source_path = /* ]] || source_path=$source_dir/$source_path
  done
  cd "$(dirname "$source_path")/../.."
  git=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH:?}
  listing=${TEST_TMPDIR:?}/mktemp-files
  "$git" ls-files -z -- '*.sh' '*.sh.tpl' '*.yml' >"$listing"
  files=()
  while IFS= read -r -d '' file; do
    # Fixtures deliberately contain the forbidden forms and run separately.
    [[ $file = repo/tests/testdata/mktemp/* ]] && continue
    files+=("$file")
  done <"$listing"
fi

if ((${#files[@]} == 0)); then
  echo 'mktemp: FAIL: no files to check' >&2
  exit 1
fi

awk '
  /(^|[^[:alnum:]_])mktemp([[:space:]]+-d)?[[:space:]]*($|[);|&`])/ {
    printf "%s:%d: bare mktemp: use mktemp [-d] \"${TMPDIR:-/tmp}/<name>.XXXXXX\" (in CI use ${RUNNER_TEMP:-${TMPDIR:-/tmp}})\n", FILENAME, FNR
    failed = 1
  }
  END { exit failed }
' "${files[@]}"
echo "mktemp: checked ${#files[@]} files"
