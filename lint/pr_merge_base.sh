#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

local_only=false
if (($# == 3)) && [[ $1 == --local ]]; then
  local_only=true
  shift
elif (($# != 2)); then
  echo 'usage: pr_merge_base BASE_REF HEAD' >&2
  exit 2
fi

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"
base="refs/remotes/origin/$1"
if $local_only; then
  base=$(git rev-parse --verify --quiet --end-of-options "$1^{commit}") || base="refs/remotes/origin/$1"
else
  git cat-file -e "$base^{commit}" 2>/dev/null || git fetch origin "refs/heads/$1:$base" >&2
fi
exec git merge-base -- "$base" "$2"
