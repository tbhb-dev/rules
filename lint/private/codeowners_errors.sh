#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"
if [[ ! -f .github/CODEOWNERS && ! -f CODEOWNERS && ! -f docs/CODEOWNERS ]]; then
  echo "::notice::Skipped CODEOWNERS owner and syntax check: no CODEOWNERS file in .github/, the repository root, or docs/."
  exit 0
fi

# Self-hosted runners may lack gh, so the call uses curl.
response="$(curl -fsSL \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/codeowners/errors?ref=${HEAD_SHA}")"
errors="$(printf '%s' "${response}" | jq '.errors')"
count="$(printf '%s' "${errors}" | jq 'length')"
if [ "${count}" -ne 0 ]; then
  echo "::error::CODEOWNERS has ${count} owner or syntax error(s):"
  printf '%s' "${errors}" |
    jq -r '.[] | "  line \(.line): \(.kind): \(.message)"'
  exit 1
fi
