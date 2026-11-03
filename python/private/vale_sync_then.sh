#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Syncs the pinned Vale packages into the copy's StylesPath, then runs a
# command. pytest_test runs it, with `vale_packages` set, for tests that
# drive vale against the repository's own configuration. vale is on PATH
# and the archives are under $XDG_CACHE_HOME/vale/packages/NNN/<name>.zip,
# in the order they were given.
#
# Usage: vale_sync_then.sh CONFIG COMMAND [ARG]...

set -euo pipefail

config=$1
shift

# StylesPath is relative to the config's directory.
styles=$(sed -nE 's/^[[:space:]]*StylesPath[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$config" | tail -n 1)
if [[ -z $styles ]]; then
  echo "vale_sync_then: $config sets no StylesPath" >&2
  exit 1
fi
styles="$(cd "$(dirname "$config")" && pwd)/$styles"
mkdir -p "$styles"

packages=()
for archive in "$XDG_CACHE_HOME"/vale/packages/*/*.zip; do
  [[ -e $archive ]] && packages+=("$archive")
done
if [[ -z ${packages[0]+set} ]]; then
  echo "vale_sync_then: no Vale packages to sync" >&2
  exit 1
fi
sync_config="$TEST_TMPDIR/vale-sync.ini"
{
  echo "StylesPath = $styles"
  printf 'Packages = %s' "${packages[0]}"
  for archive in "${packages[@]:1}"; do
    printf ', %s' "$archive"
  done
  echo
} >"$sync_config"
vale --config="$sync_config" sync >/dev/null

exec "$@"
