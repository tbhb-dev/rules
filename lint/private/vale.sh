#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Lints prose with Vale against pinned style packages. Run by vale_test at
# the root of its copy of the tree, with vale on PATH and the package
# archives under $XDG_CACHE_HOME/vale/packages, named so they sort in the
# order the rule was given them (NNN/<name>.zip).
#
# Usage: vale.sh CONFIG [--include PATTERN]...
#
# The files to lint are chosen before the packages are synced, so the
# synced styles are never linted themselves. PATTERN is a bash [[ == ]]
# pattern matched against the tree-relative path and the basename.

set -euo pipefail

config=$1
shift
includes=()
while (($#)); do
  case $1 in
  --include)
    includes+=("$2")
    shift 2
    ;;
  *)
    echo "vale: unexpected argument '$1'" >&2
    exit 2
    ;;
  esac
done

listing="$TEST_TMPDIR/vale.files"
find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z >"$listing"
files=()
while IFS= read -r -d '' file; do
  file=${file#./}
  for pattern in ${includes[@]+"${includes[@]}"}; do
    # shellcheck disable=SC2053 # The pattern is a glob on purpose.
    if [[ $file == $pattern || ${file##*/} == $pattern ]]; then
      files+=("$file")
      break
    fi
  done
done <"$listing"
if [[ -z ${files[0]+set} ]]; then
  echo "vale: no files match ${includes[*]-}, so nothing was checked" >&2
  exit 1
fi

# StylesPath is relative to the config's directory.
styles=$(sed -nE 's/^[[:space:]]*StylesPath[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$config" | tail -n 1)
if [[ -z $styles ]]; then
  echo "vale: $config sets no StylesPath" >&2
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

# vale sync from local archives: the same unpacking `vale sync` does from
# the URLs in the config, with nothing fetched.
packages=()
for archive in "$XDG_CACHE_HOME"/vale/packages/*/*.zip; do
  [[ -e $archive ]] || continue
  archive=$(native_path "$archive")
  packages+=("$archive")
done
if [[ -n ${packages[0]+set} ]]; then
  sync_config="$TEST_TMPDIR/vale-sync.ini"
  sync_styles=$(native_path "$styles")
  {
    echo "StylesPath = $sync_styles"
    printf 'Packages = %s' "${packages[0]}"
    for archive in "${packages[@]:1}"; do
      printf ', %s' "$archive"
    done
    echo
  } >"$sync_config"
  vale --config="$sync_config" sync >/dev/null
fi

# Add the shared vocabulary to the scratch config, preserving the project's
# vocabularies and all paths relative to its config directory.
vocabulary="$styles/config/vocabularies/tbhb_rules"
mkdir -p "$vocabulary"
cp "$XDG_CACHE_HOME/vale/words.txt" "$vocabulary/accept.txt"
touch "$vocabulary/reject.txt"
for accept in "$styles"/config/vocabularies/*/accept.txt; do
  # Each expression still requires an accepted base word. Comments and empty
  # lines stay unchanged, and a typo in the base never becomes an exception.
  sed -E "/^#|^[[:space:]]*$/!s/^(.*)$/(\\1)(['’]s)?/" "$accept" >"$accept.tmp"
  mv "$accept.tmp" "$accept"
done
shared_config="$(dirname "$config")/.tbhb-vale.ini"
awk '
  BEGIN { global = 1; found = 0 }
  /^\[/ && global {
    if (!found) print "Vocab = tbhb_rules"
    global = 0
  }
  global && /^[[:space:]]*Vocab[[:space:]]*=/ {
    $0 = $0 ", tbhb_rules"
    found = 1
  }
  { print }
  END { if (global && !found) print "Vocab = tbhb_rules" }
' "$config" >"$shared_config"

echo "vale: linting ${#files[@]} files with ${#packages[@]} packages"
exec vale --config="$shared_config" --no-wrap "${files[@]}"
