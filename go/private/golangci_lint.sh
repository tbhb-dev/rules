#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs golangci-lint over one package, loading it through the static
# packages driver, and writes a findings report (empty when clean). Run by
# the golangci-lint aspect in golangci_lint.bzl from the execution root.
#
# Usage: golangci_lint.sh GOLANGCI_LINT REPORT DRIVER DRIVER_CONFIG GO CONFIG
#        GO_MOD MIRROR_FILES REPORT_OUT [golangci-lint run flags...]
#
# GO_MOD is empty when there is none. MIRROR_FILES lists the files to copy
# into the mirror: the package's sources, the config, go.mod and the
# config's data.

set -euo pipefail

golangci_lint=$1
report=$2
driver=$3
driver_config=$4
go=$5
config=$6
go_mod=$7
mirror_files=$8
report_out=$9
shift 9

root=$(pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/golangci-lint.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# golangci-lint resolves symlinks in its working directory and config path
# but not in source paths, and computes the relative paths that exclusion
# rules match from the two. In a sandbox every input is a symlink into the
# source tree, so the config's directory would resolve outside the sandbox.
# A mirror of real copies, at a symlink-free path, keeps both sides inside
# it; the driver reports mirrored sources at their copies. Design change
# from PR #901, which ran on the execroot's symlinks. Sources in
# golangci-lint 2.15.0: pkg/fsutils/fsutils.go Getwd (EvalSymlinks of the
# working directory), EvalSymlinks and ShortestRelPath; and
# pkg/config/base_loader.go BaseLoader.setConfigDir, which takes the
# config directory from the resolved config path. Revisit if those stop
# resolving symlinks or gain an option to keep them.
tmp=$(cd "$tmp" && pwd -P)
ws="$tmp/ws"
mkdir -p "$ws" "$tmp/home"
while IFS= read -r f; do
  mkdir -p "$ws/$(dirname "$f")"
  cp "$f" "$ws/$f"
done <"$mirror_files"

# golangci-lint asks `go env` for its build context, so the SDK's go must be
# on PATH; Go refuses to run a go binary found by a relative path.
goroot=$(dirname "$(dirname "$root/$go")")
export GOROOT=$goroot
export PATH="$goroot/bin:$PATH"

export GOPACKAGESDRIVER="$root/$driver"
export GOPACKAGESDRIVER_CONFIG="$root/$driver_config"
export GOPACKAGESDRIVER_ROOT="$root"
export GOPACKAGESDRIVER_MIRROR="$ws"

# Nothing outside the sandbox: empty caches of its own, no module proxy, no
# toolchain switch, no workspace file, no telemetry. golangci-lint takes a
# lock file in TMPDIR (pkg/commands/run.go, runCommand.acquireFileLock:
# $TMPDIR/golangci-lint.lock), so with a shared TMPDIR concurrent actions
# would wait on each other or fail with "parallel golangci-lint is
# running"; a private one per action avoids that. Design change from PR
# #901. --allow-parallel-runners (pkg/commands/flagsets.go) would skip the
# lock too; a private TMPDIR also keeps every other temporary file in the
# action.
export HOME="$tmp/home"
export TMPDIR="$tmp"
# Go's os.TempDir reads TMP and TEMP on Windows.
export TMP="$tmp" TEMP="$tmp"
export GOCACHE="$tmp/gocache"
export GOLANGCI_LINT_CACHE="$tmp/golangci-lint"
export GOPATH="$tmp/gopath"
export GOMODCACHE="$tmp/gopath/pkg/mod"
export GOPROXY=off
export GOTOOLCHAIN=local
export GOWORK=off
export GOTELEMETRY=off
export GOFLAGS=-mod=mod

# x/tools' export data importer races when several goroutines decode at once
# (golang/go#34895, #67725, #70015); one P makes that practically never
# happen. A package is small, so little is lost.
export GOMAXPROCS=1

# Run from the module root, as `golangci-lint run` would be, so the Go
# version and `relative-path-mode: gomod` come from go.mod.
moddir=$ws
if [[ -n $go_mod ]]; then
  moddir="$ws/$(dirname "$go_mod")"
fi

status=0
(
  cd "$moddir"
  "$root/$golangci_lint" run \
    --config "$ws/$config" \
    --path-mode=abs \
    --show-stats=false \
    --output.json.path="$tmp/issues.json" \
    "$@" \
    ./...
) >"$tmp/log" 2>&1 || status=$?

"$root/$report" \
  -in "$tmp/issues.json" \
  -exit "$status" \
  -log "$tmp/log" \
  -base "$ws" \
  -out "$root/$report_out"
