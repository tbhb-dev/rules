#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Writes the pinned Vale packages into the workspace's StylesPath, for
# editors and for running vale by hand. Generated from vale_sync.sh.tpl by
# the vale_sync rule; run it with `bazel run`.

set -euo pipefail

runfiles=$PWD
vale="$runfiles/@@VALE@@"
config=@@CONFIG@@
packages=(@@PACKAGES@@)
names=(@@NAMES@@)

cd "${BUILD_WORKSPACE_DIRECTORY:?run this with bazel run}"
styles=$(sed -nE 's/^[[:space:]]*StylesPath[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$config" | tail -n 1)
if [[ -z $styles ]]; then
  echo "vale_sync: $config sets no StylesPath" >&2
  exit 1
fi
styles="$(cd "$(dirname "$config")" && pwd)/$styles"

# The path as vale.exe reads it on Windows (C:/...); MSYS paths (/c/...) only
# mean something to the shell. Elsewhere it is unchanged.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

mkdir -p "$styles"

# vale names a package by its archive's file name, so each archive is
# staged under its package name first.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archives=()
for i in "${!packages[@]}"; do
  mkdir -p "$work/$i"
  cp "$runfiles/${packages[i]}" "$work/$i/${names[i]}.zip"
  archive=$(native_path "$work/$i/${names[i]}.zip")
  archives+=("$archive")
done
sync_styles=$(native_path "$styles")
{
  echo "StylesPath = $sync_styles"
  printf 'Packages = %s' "${archives[0]}"
  for archive in "${archives[@]:1}"; do
    printf ', %s' "$archive"
  done
  echo
} >"$work/sync.ini"
"$vale" --config="$work/sync.ini" sync
