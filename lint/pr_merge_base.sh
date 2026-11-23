#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

if (($# != 2)); then
  echo 'usage: pr_merge_base BASE_REF HEAD' >&2
  exit 2
fi

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"
base="refs/remotes/origin/$1"
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch origin "refs/heads/$1:$base" >&2
exec git merge-base -- "$base" "$2"
