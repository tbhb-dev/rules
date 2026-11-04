#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# This repository's .gitattributes keeps the composite actions in the source
# archive. GitHub's runner fetches a remote action as the archive at the
# pinned commit, so an export-ignored action.yml breaks every consumer's
# `uses:`. The test commits a scratch tree under the real .gitattributes and
# lists `git archive`.
#
# GIT_RLOCATIONPATH and GITATTRIBUTES_RLOCATIONPATH are runfiles paths.

set -euo pipefail

git=${TEST_SRCDIR:?}/${GIT_RLOCATIONPATH:?}
attributes=${TEST_SRCDIR:?}/${GITATTRIBUTES_RLOCATIONPATH:?}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

repo=${TEST_TMPDIR:?}/repo
mkdir -p "$repo"
cd "$repo"
cp -- "$attributes" .gitattributes
mkdir -p .github/actions/example .github/workflows tools
for file in .github/actions/example/action.yml .github/actions/README.md \
  .github/workflows/ci.yml tools/BUILD.bazel MODULE.bazel; do
  echo x >"$file"
done

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
"$git" init -q -b main .
"$git" add -A
"$git" -c user.name=test -c user.email=test@example.invalid \
  -c commit.gpgsign=false commit -q -m test
listing=$("$git" archive HEAD | tar -t)

kept=(.github/actions/example/action.yml .github/actions/README.md MODULE.bazel)
dropped=(.github/workflows/ci.yml tools/BUILD.bazel)
for path in "${kept[@]}"; do
  grep -qxF -- "$path" <<<"$listing" || fail "$path is missing from the archive"
done
for path in "${dropped[@]}"; do
  if grep -qxF -- "$path" <<<"$listing"; then
    fail "$path is in the archive"
  fi
done
echo "PASS: the archive keeps .github/actions and drops the rest of .github"
