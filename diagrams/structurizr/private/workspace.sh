#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
export LC_ALL=en_US.UTF-8

error() {
  echo "structurizr_workspace: error: $*" >&2
  exit 2
}

# Each JVM refuses HTTP(S) connections. PlantUML's sandbox profile also
# disables includes and local file access from the exported diagram text.
java_run() {
  "$java" -Djava.awt.headless=true -Duser.timezone=UTC \
    -Duser.language=en -Duser.country=US -Djava.net.useSystemProxies=false \
    -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=9 \
    -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=9 \
    -Dhttp.nonProxyHosts= -Dplantuml.security.profile=SANDBOX "$@"
}

cli_run() {
  java_run -cp "$cli/*" com.structurizr.cli.StructurizrCliApplication "$@"
}

lint() {
  local validate_status=0 inspect_status=0
  cli_run validate -w "$dsl" >"$scratch/validate.log" 2>&1 || validate_status=$?
  cli_run inspect -w "$dsl" -s error,warning >"$scratch/inspect.log" 2>&1 || inspect_status=$?
  if ((validate_status)); then
    echo "validate: workspace failed validation"
    cat "$scratch/validate.log"
  fi
  # Inspect exits with the number of displayed violations. Also check its
  # output, because 256 violations wrap the process exit status to zero.
  # The pinned CLI is silent for a clean error,warning inspection (covered
  # by workspace_lint_test). Treat any unexpected output as a failure too.
  if ((inspect_status)) || [[ -s $scratch/inspect.log ]]; then
    echo "inspect: workspace failed inspection (ERROR,WARNING)"
    cat "$scratch/inspect.log"
    inspect_status=1
  fi
  if ((validate_status || inspect_status)); then return 1; fi
}

render() {
  lint
  mkdir -p "$out/diagrams"
  cli_run export -w "$dsl" -f json -o "$out"
  cli_run export -w "$dsl" -f plantuml -o "$out/diagrams"
  [[ -f $out/workspace.json ]] || error "export produced no workspace.json"
  shopt -s nullglob
  local sources=("$out/diagrams/"*.puml) source
  ((${#sources[@]})) || error "export produced no PlantUML views"
  for source in "${sources[@]}"; do
    awk '{print} /^@startuml/ && !inserted++ {print "!pragma layout smetana\nskinparam defaultFontName Liberation Sans"}' "$source" >"$source.tmp"
    mv "$source.tmp" "$source"
  done
  # Fontconfig must never discover host font directories on Linux. Java on
  # macOS uses its native font manager; debugfonts below verifies the TTF used.
  [[ -f $fonts/LiberationSans-Regular.ttf ]] || error "pinned Liberation Sans font is missing"
  mkdir -p "$scratch/pinned-fonts"
  cp -L "$fonts/"*.ttf "$scratch/pinned-fonts/"
  fonts=$(cd "$scratch/pinned-fonts" && pwd -P)
  mkdir -p "$scratch/font-cache"
  # Escape paths for XML, including scratch paths supplied by Bazel.
  local font_dir cache_dir
  font_dir=$(printf '%s' "$fonts" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  cache_dir=$(printf '%s' "$scratch/font-cache" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  export FONTCONFIG_FILE="$scratch/fonts.conf"
  printf '<fontconfig><dir>%s</dir><cachedir>%s</cachedir></fontconfig>\n' "$font_dir" "$cache_dir" >"$FONTCONFIG_FILE"
  java_run -Dsun.java2d.debugfonts=true "-Dsun.java2d.fontpath=$fonts" -jar "$plantuml" -failfast2 -tsvg "${sources[@]}" >"$scratch/fonts.log" 2>&1 || {
    cat "$scratch/fonts.log"
    error "SVG rendering failed"
  }
  local face
  for face in Regular Bold Italic BoldItalic; do
    grep -F "Registered file $fonts/LiberationSans-$face.ttf as font ** TrueType Font: Family=Liberation Sans " "$scratch/fonts.log" >/dev/null || {
      cat "$scratch/fonts.log"
      error "JVM did not use the pinned Liberation Sans TTF: $face"
    }
  done
  java_run "-Dsun.java2d.fontpath=$fonts" -jar "$plantuml" -failfast2 -tpng "${sources[@]}"
  for source in "${sources[@]}"; do
    local families
    families=$(grep -o '<text[^>]*' "${source%.puml}.svg" | grep -o 'font-family="[^"]*"' | sort -u)
    [[ $families == 'font-family="Liberation Sans"' ]] || error "SVG does not use only Liberation Sans: ${source##*/}"
    [[ -s ${source%.puml}.svg && -s ${source%.puml}.png ]] || error "render produced no images for ${source##*/}"
  done
}

# The manifest maps output-relative names to source files in the runfiles
# tree. It is generated at analysis time, so missing files remain visible.
check() {
  local relative committed fresh found problems=0
  shopt -s nullglob
  local files=("$out/workspace.json" "$out/diagrams/"*.svg "$out/diagrams/"*.png)
  for fresh in "${files[@]}"; do
    relative=${fresh#"$out/"}
    found=0
    while IFS=$'\t' read -r expected committed; do
      if [[ $expected == "$relative" ]]; then
        found=1
        if [[ $mode == png && $relative != *.png ]] || [[ $mode == check && $relative == *.png ]]; then break; fi
        local compare_status=0
        cmp -s "$fresh" "$committed" || compare_status=$?
        case $compare_status in
        0) ;;
        1)
          echo "stale: $relative differs from a fresh render"
          problems=$((problems + 1))
          ;;
        *) error "cannot compare $relative (cmp exited $compare_status)" ;;
        esac
        break
      fi
    done <"$manifest"
    if ((found == 0)); then
      echo "missing: $relative"
      problems=$((problems + 1))
    fi
  done
  while IFS=$'\t' read -r relative committed; do
    if [[ ! -f $out/$relative ]]; then
      echo "orphan: $relative has no workspace view"
      problems=$((problems + 1))
    fi
  done <"$manifest"
  if ((problems)); then return 1; fi
  echo "structurizr_workspace: committed exports are current"
}

update() {
  [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} ]] || error "use bazel run for updates"
  local fresh relative destination
  mkdir -p "$BUILD_WORKSPACE_DIRECTORY/$diagrams_dir" "$(dirname "$BUILD_WORKSPACE_DIRECTORY/$workspace_json")"
  cp "$out/workspace.json" "$BUILD_WORKSPACE_DIRECTORY/$workspace_json"
  chmod 0644 "$BUILD_WORKSPACE_DIRECTORY/$workspace_json"
  shopt -s nullglob
  for fresh in "$out/diagrams/"*.svg "$out/diagrams/"*.png; do
    destination="$BUILD_WORKSPACE_DIRECTORY/$diagrams_dir/${fresh##*/}"
    cp "$fresh" "$destination"
    chmod 0644 "$destination"
  done
  while IFS=$'\t' read -r relative destination; do
    if [[ $relative == diagrams/* && ! -f $out/$relative ]]; then
      rm -f "$BUILD_WORKSPACE_DIRECTORY/$diagrams_dir/${relative#diagrams/}"
    fi
  done <"$manifest"
}

mode=$1
shift
case $mode in
lint | render)
  java=$1 cli=$2 dsl_relative=$3
  scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/structurizr.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  if [[ $mode == render ]]; then
    plantuml=$4 out=$5 fonts=$6
    shift 6
  else
    shift 3
  fi
  # Copy declared inputs into real files. The documentation importer trims
  # canonical paths, which leaks source paths when its inputs are symlinks.
  while (($#)); do
    mkdir -p "$scratch/source/$(dirname "$2")"
    cp -L "$1" "$scratch/source/$2"
    shift 2
  done
  dsl="$scratch/source/$dsl_relative"
  if [[ $mode == lint ]]; then lint; else render; fi
  ;;
check | png)
  out=$1 manifest=$2
  check
  ;;
update)
  out=$1 manifest=$2 workspace_json=$3 diagrams_dir=$4
  update
  ;;
*) error "unknown operation: $mode" ;;
esac
