#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# One step of rendering a D2 diagram. Run by d2_diagrams' actions
# (d2_diagrams.bzl) from the execution root.
#
# Usage: render.sh svg D2 SRC SVG_OUT
#        render.sh png RESVG OXIPNG SANS_DIR MONO_DIR SRC SVG PNG_OUT
#        render.sh manifest SRC SVG PNG SHA256_OUT
#
# svg: D2's own SVG, ending in exactly one newline. A source with a remote
# image fails: no render reaches the network.
# png: the SVG rasterized at twice its size, with D2's embedded font
# families rewritten to the installed Source Sans Pro and Source Code Pro
# (resvg skips @font-face), then optimized. SRC names the diagram in
# messages. An SVG with a font family the rewrite doesn't know fails.
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

# No network either. d2 fetches remote images (`icon: https://...`) to
# inline them; every HTTP(S) request goes through a proxy on port 0, which
# nothing can listen on, so it fails at once and d2 names the URL.
export HTTP_PROXY=http://127.0.0.1:0 HTTPS_PROXY=http://127.0.0.1:0
unset NO_PROXY no_proxy

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

# error MESSAGE: a step that could not run.
error() {
  echo "render.sh: error: $1" >&2
  exit 2
}

# digest FILE: sets hash to FILE's SHA-256, read from standard input so no
# tool marks the name with its read mode. macOS has shasum but not always
# sha256sum. The same function is in check.sh.tpl and write.sh.tpl; a
# change goes to all three.
digest() {
  local line
  if command -v sha256sum >/dev/null; then
    line=$(sha256sum <"$1") || error "cannot hash $1 with sha256sum"
  elif command -v shasum >/dev/null; then
    line=$(shasum -a 256 <"$1") || error "cannot hash $1 with shasum"
  else
    error "cannot hash $1: neither sha256sum nor shasum is on PATH"
  fi
  hash=${line%% *}
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || error "cannot hash $1: the hash tool printed '$line'"
}

mode=$1
shift
case $mode in
svg)
  d2=$1 src=$2 svg_out=$3
  status=0
  "$root/$d2" "$src" "$tmp/raw.svg" >"$tmp/log" 2>&1 || status=$?
  if ((status != 0)); then
    if grep -q 'failed to bundle remote images' "$tmp/log"; then
      echo "render.sh: error: $src uses a remote image, which d2 would fetch at build time." \
        "Save it beside the source, list it in data, and refer to it by its relative path:" >&2
    else
      echo "render.sh: d2 failed with exit status $status:" >&2
    fi
    cat "$tmp/log" >&2
    exit "$status"
  fi
  # Command substitution drops every trailing newline; printf adds one.
  printf '%s\n' "$(<"$tmp/raw.svg")" >"$svg_out"
  ;;
png)
  resvg=$1 oxipng=$2 sans_dir=$3 mono_dir=$4 src=$5 svg=$6 png_out=$7
  sed -E \
    -e 's/font-family: "d2-[0-9]+-font-regular";/font-family: "Source Sans Pro";/' \
    -e 's/font-family: "d2-[0-9]+-font-bold";/font-family: "Source Sans Pro"; font-weight: bold;/' \
    -e 's/font-family: "d2-[0-9]+-font-semibold";/font-family: "Source Sans Pro"; font-weight: 600;/' \
    -e 's/font-family: "d2-[0-9]+-font-italic";/font-family: "Source Sans Pro"; font-style: italic;/' \
    -e 's/font-family: "d2-[0-9]+-font-mono";/font-family: "Source Code Pro";/' \
    -e 's/font-family: "d2-[0-9]+-font-mono-bold";/font-family: "Source Code Pro"; font-weight: bold;/' \
    -e 's/font-family: "d2-[0-9]+-font-mono-semibold";/font-family: "Source Code Pro"; font-weight: 600;/' \
    -e 's/font-family: "d2-[0-9]+-font-mono-italic";/font-family: "Source Code Pro"; font-style: italic;/' \
    "$svg" >"$tmp/png.svg"
  # resvg draws a family it has no font for in another font, or not at
  # all, without a word: refuse instead. d2 0.9.0 emits only the families
  # above; a newer d2 may add one.
  found=0
  grep -oE 'font-family: "d2-[0-9]+-font-[^"]*"' "$tmp/png.svg" >"$tmp/unmapped" || found=$?
  case $found in
  0)
    families=$(sed -E 's/^font-family: "(.*)"$/\1/' "$tmp/unmapped" | sort -u | tr '\n' ' ')
    echo "render.sh: error: cannot draw $src as PNG: no installed font for these font families in its SVG: ${families% }" >&2
    exit 1
    ;;
  1) ;;
  *) error "cannot search the SVG of $src for font families (grep exited $found)" ;;
  esac
  run "$root/$resvg" --quiet --skip-system-fonts --use-fonts-dir "$root/$sans_dir" --use-fonts-dir "$root/$mono_dir" \
    --zoom 2 "$tmp/png.svg" "$png_out"
  run "$root/$oxipng" --quiet --opt 4 --strip safe "$png_out"
  ;;
manifest)
  src=$1 svg=$2 png=$3 sha256_out=$4
  name=${src##*/}
  digest "$src"
  src_hash=$hash
  digest "$svg"
  svg_hash=$hash
  digest "$png"
  png_hash=$hash
  printf '%s  %s\n' "$src_hash" "$name" "$svg_hash" "$name.svg" "$png_hash" "$name.png" >"$sha256_out"
  ;;
*)
  echo "render.sh: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
