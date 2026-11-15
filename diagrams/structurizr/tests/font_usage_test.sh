#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

# Stand in for Java at the runner boundary. Rendering and font discovery are
# separate: an SVG's font-family alone cannot prove which TTF Java used.
if [[ ${1:-} == -Djava.awt.headless=true ]]; then
  format='' destination='' fonts=''
  while (($#)); do
    case $1 in
    -f)
      format=$2
      shift
      ;;
    -o)
      destination=$2
      shift
      ;;
    -Dsun.java2d.fontpath=*) fonts=${1#*=} ;;
    -tsvg | -tpng) format=${1#-t} ;;
    esac
    shift
  done
  case $format in
  json) echo '{}' >"$destination/workspace.json" ;;
  plantuml) printf '@startuml\n@enduml\n' >"$destination/view.puml" ;;
  svg)
    printf '<text font-family="Liberation Sans">text</text>\n' >"$STUB_OUT/diagrams/view.svg"
    for face in Regular Bold Italic BoldItalic; do
      file=$fonts/LiberationSans-$face.ttf
      family="Liberation Sans"
      if [[ $face == "${STUB_BAD_FACE:-}" ]]; then
        case $STUB_BAD_KIND in
        missing) continue ;;
        system) file=/system/fonts/LiberationSans-$face.ttf ;;
        suffix) file=$file.other ;;
        family) family='Other Sans' ;;
        esac
      fi
      case $STUB_LOG in
      registered) echo "INFO: Registered file $file as font ** TrueType Font: Family=$family Name=font" ;;
      fc) echo "INFO: FC font sans:regular:italic maps to family $family in file $file" ;;
      esac
    done
    ;;
  png) echo image >"$STUB_OUT/diagrams/view.png" ;;
  esac
  exit 0
fi

runfiles=${RUNFILES_DIR:-${TEST_SRCDIR:?}}
runner=$runfiles/$1
scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/font-usage.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/fonts" "$scratch/bin"
for face in Regular Bold Italic BoldItalic; do
  touch "$scratch/fonts/LiberationSans-$face.ttf"
done
# The stub expands the operating system when the runner invokes it.
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$STUB_OS"\n' >"$scratch/bin/uname"
chmod +x "$scratch/bin/uname"
export PATH=$scratch/bin:$PATH

fail() {
  echo "font_usage_test: $*" >&2
  cat "$scratch/render.log" >&2
  exit 1
}

render_on() {
  export STUB_OS=$1 STUB_LOG=$2 STUB_BAD_FACE=${3:-} STUB_BAD_KIND=${4:-}
  export STUB_OUT=$scratch/out
  rm -rf "$STUB_OUT"
  status=0
  "$runner" render "$0" unused workspace.dsl unused "$STUB_OUT" "$scratch/fonts" >"$scratch/render.log" 2>&1 || status=$?
}

for os in Linux Darwin; do
  if [[ $os == Linux ]]; then log='fc'; else log=registered; fi
  render_on "$os" "$log"
  [[ $status == 0 ]] || fail "$os rejected pinned $log fonts (exit $status)"
  for face in Regular Bold Italic BoldItalic; do
    for kind in system missing suffix family; do
      render_on "$os" "$log" "$face" "$kind"
      [[ $status == 2 ]] || fail "$os accepted $kind $face (exit $status)"
      grep -F "JVM did not use the pinned Liberation Sans TTF: $face" "$scratch/render.log" >/dev/null || fail "missing diagnostic for $os $kind $face"
    done
  done
done

# Eager registration remains valid on Linux. Fontconfig mappings alone must
# never satisfy the native macOS font manager's registration check.
render_on Linux registered
[[ $status == 0 ]] || fail "Linux rejected registered pinned fonts"
render_on Darwin fc
[[ $status == 2 ]] || fail "Darwin accepted only fontconfig mappings"
