#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Scans the text on stdin with gitleaks, under the workspace's .gitleaks.toml
# when it has one. Generated from gitleaks_text.sh.tpl; the @@NAME@@ markers
# are filled in at analysis time. Run with `bazel run`. Arguments go to
# `gitleaks stdin`. A failing scan also names each finding's rule and line on
# stderr, never its text.

set -euo pipefail

tool="$PWD/@@TOOL@@"

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"

# The private config extends .gitleaks.toml at the workspace root, which
# gitleaks_tool requires by that name.
args=(stdin --redact --no-banner)
if [[ -f .gitleaks.toml ]]; then
  args+=(--config .gitleaks.toml)
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT
args+=(--report-format json --report-path "$report")

status=0
"$tool" "${args[@]}" "$@" || status=$?

# gitleaks writes the report as indented JSON, one field per line, with
# string values escaped onto a single line. Matching the finding fields by
# their indent therefore cannot pick up text from inside a value.
if [[ -s $report ]]; then
  awk '
    /^  "RuleID": "/ { rule = $2; gsub(/[",]/, "", rule) }
    /^  "StartLine": / { line = $2; gsub(/,/, "", line) }
    /^ }/ {
      if (rule != "" && line != "") print "gitleaks_text: rule=" rule " line=" line
      rule = ""; line = ""
    }
  ' "$report" >&2
fi
exit "$status"
