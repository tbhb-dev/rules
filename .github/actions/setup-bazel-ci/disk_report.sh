#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Prints the disk, temp directory and swap state of a macOS runner, to the log
# and to the job summary. It only reads, and it always succeeds: it exists to
# name the cause of a `tar: Write error` in a test wrapper, not to gate a job.
# Usage: disk_report.sh LABEL
set -uo pipefail

[[ ${RUNNER_OS:-} == macOS ]] || exit 0

report() {
  local tmp=${TMPDIR:-/tmp}
  echo "TMPDIR=${TMPDIR:-unset}"
  local base
  base=$(bazelisk info output_base 2>/dev/null) || base=
  echo "Bazel output base: ${base:-unknown}"
  echo
  df -h "$HOME" "$tmp" ${base:+"$base"} 2>&1
  echo
  ls -ld "$tmp" 2>&1
  echo
  sysctl vm.swapusage 2>&1
}

echo "::group::macOS disk and temp space: ${1:-report}"
out=$(report)
printf '%s\n' "$out"
echo "::endgroup::"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  # shellcheck disable=SC2016  # the backticks are Markdown
  printf '### macOS disk and temp space: %s\n\n```text\n%s\n```\n' "${1:-report}" "$out" >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
