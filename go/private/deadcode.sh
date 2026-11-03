#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs deadcode over a program loaded through the static packages driver and
# writes its findings, with paths relative to the execution root. Run by
# go_deadcode_test (deadcode.bzl) from the execution root.
#
# Usage: deadcode.sh @PARAMS
#
# PARAMS holds one argument per line: DEADCODE DRIVER DRIVER_CONFIG GO
# REPORT_OUT [deadcode flags...]. The flags can hold shell metacharacters,
# which the Windows launcher would not survive on a command line.

set -euo pipefail

params=()
while IFS= read -r line || [[ -n $line ]]; do
  params+=("${line%$'\r'}")
done <"${1#@}"
set -- "${params[@]}"

deadcode=$1
driver=$2
driver_config=$3
go=$4
report_out=$5
shift 5

root=$(pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"

goroot=$(dirname "$(dirname "$root/$go")")
export GOROOT=$goroot
export PATH="$goroot/bin:$PATH"
export GOPACKAGESDRIVER="$root/$driver"
export GOPACKAGESDRIVER_CONFIG="$root/$driver_config"
export GOPACKAGESDRIVER_ROOT="$root"
export HOME="$tmp/home"
export TMPDIR="$tmp"
export GOCACHE="$tmp/gocache"
export GOPATH="$tmp/gopath"
export GOPROXY=off
export GOTOOLCHAIN=local
export GOWORK=off
export GOTELEMETRY=off

status=0
"$root/$deadcode" "$@" ./... >"$tmp/out" 2>"$tmp/err" || status=$?
if ((status != 0)); then
  {
    echo "deadcode did not complete: exit status $status"
    cat "$tmp/err"
  } >"$report_out"
  exit 0
fi
# Positions are absolute; report them relative to the execution root.
# Windows spells them with backslashes.
sed -e 's|\\|/|g' -e "s|^$root/||" "$tmp/out" >"$report_out"
