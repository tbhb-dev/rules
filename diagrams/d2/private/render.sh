#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# One step of rendering a D2 diagram. Run by d2_diagrams' actions
# (d2_diagrams.bzl) from the execution root.
#
# Usage: render.sh svg D2 SRC SVG_OUT
#        render.sh png RESVG OXIPNG FONT_DIR SVG PNG_OUT
#        render.sh manifest SRC SVG PNG SHA256_OUT
#
# svg: D2's own SVG, ending in exactly one newline.
# png: the SVG rasterized at twice its size, with D2's embedded font
# families rewritten to the installed Source Sans Pro (resvg skips
# @font-face), then optimized.
# manifest: `shasum -a 256` lines for SRC, SVG and PNG, named after SRC's
# basename as they sit beside it.

set -euo pipefail

root=$(pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Nothing from the user's home, caches or temporary files: d2 and resvg get
# private ones (USERPROFILE, APPDATA and LOCALAPPDATA are Windows' homes and
# caches).
mkdir "$tmp/home"
export HOME="$tmp/home" USERPROFILE="$tmp/home"
export XDG_CACHE_HOME="$tmp/home/.cache" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share"
export APPDATA="$tmp/home/AppData/Roaming" LOCALAPPDATA="$tmp/home/AppData/Local"
export TMPDIR="$tmp" TMP="$tmp" TEMP="$tmp"

# The tool's output is shown only when it fails.
run() {
  local status=0
  "$@" >"$tmp/log" 2>&1 || status=$?
  if ((status != 0)); then
    echo "render.sh: ${1##*/} failed with exit status $status:" >&2
    cat "$tmp/log" >&2
    exit "$status"
  fi
}

# A file's SHA-256, read from standard input so no tool marks the name with
# its read mode. macOS has shasum but not always sha256sum.
digest() {
  local line
  if command -v sha256sum >/dev/null; then
    line=$(sha256sum <"$1")
  else
    line=$(shasum -a 256 <"$1")
  fi
  printf '%s' "${line%% *}"
}

mode=$1
shift
case $mode in
svg)
  d2=$1 src=$2 svg_out=$3
  run "$root/$d2" "$src" "$tmp/raw.svg"
  # Command substitution drops every trailing newline; printf adds one.
  printf '%s\n' "$(<"$tmp/raw.svg")" >"$svg_out"
  ;;
png)
  resvg=$1 oxipng=$2 font_dir=$3 svg=$4 png_out=$5
  sed -E \
    -e 's/font-family: "d2-[0-9]+-font-regular";/font-family: "Source Sans Pro";/' \
    -e 's/font-family: "d2-[0-9]+-font-bold";/font-family: "Source Sans Pro"; font-weight: bold;/' \
    -e 's/font-family: "d2-[0-9]+-font-italic";/font-family: "Source Sans Pro"; font-style: italic;/' \
    "$svg" >"$tmp/png.svg"
  run "$root/$resvg" --quiet --skip-system-fonts --use-fonts-dir "$root/$font_dir" --zoom 2 "$tmp/png.svg" "$png_out"
  run "$root/$oxipng" --quiet --opt 4 --strip safe "$png_out"
  ;;
manifest)
  src=$1 svg=$2 png=$3 sha256_out=$4
  name=${src##*/}
  src_hash=$(digest "$src")
  svg_hash=$(digest "$svg")
  png_hash=$(digest "$png")
  printf '%s  %s\n' "$src_hash" "$name" "$svg_hash" "$name.svg" "$png_hash" "$name.png" >"$sha256_out"
  ;;
*)
  echo "render.sh: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
