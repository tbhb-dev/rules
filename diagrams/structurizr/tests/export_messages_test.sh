#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail

runfiles=${RUNFILES_DIR:-${TEST_SRCDIR:?}}
runner=$runfiles/$1
scratch=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/export-messages.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/fresh/diagrams" "$scratch/committed/diagrams"
printf '{}\n' >"$scratch/fresh/workspace.json"
printf '<svg/>\n' >"$scratch/fresh/diagrams/view.svg"
printf 'image\n' >"$scratch/fresh/diagrams/view.png"
for relative in workspace.json diagrams/view.svg diagrams/view.png; do
  cp "$scratch/fresh/$relative" "$scratch/committed/$relative"
  printf '%s\t%s\n' "$relative" "$scratch/committed/$relative" >>"$scratch/manifest"
done

problems=0
for mode in check png; do
  if [[ $mode == check ]]; then
    expected='structurizr_workspace: committed JSON and SVG exports are current
structurizr_workspace: PNG bytes were not compared by this test; the PNG test compares them on macOS arm64 only'
  else
    expected='structurizr_workspace: committed PNG exports are current'
  fi
  actual=$("$runner" "$mode" "$scratch/fresh" "$scratch/manifest")
  if [[ $actual != "$expected" ]]; then
    printf 'export_messages_test: %s message differs\nexpected:\n%s\nactual:\n%s\n' "$mode" "$expected" "$actual" >&2
    problems=$((problems + 1))
  else
    printf '%s: %s\n' "$mode" "$actual"
  fi
done
((problems == 0))
