#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The pinned Git speaks HTTPS: lists a public repository's HEAD. Needs the
# network, so its target is manual.
#
# GIT_RLOCATIONPATH is the git target's runfiles path.

set -euo pipefail

git=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH:?}
export GIT_CONFIG_GLOBAL=/dev/null

output=$("$git" ls-remote https://github.com/tbhb-dev/rules.git HEAD)
echo "$output"
[[ $output =~ ^[0-9a-f]{40}[[:space:]]HEAD$ ]] || {
  echo "FAIL: ls-remote printed no HEAD" >&2
  exit 1
}
