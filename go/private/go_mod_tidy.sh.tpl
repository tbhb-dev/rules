#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs `go mod tidy -diff` and `go mod verify` over a copy of a module,
# offline. Generated from go_mod_tidy.sh.tpl by go_mod_tidy_test; the
# @@NAME@@ markers are filled in at analysis time.

set -euo pipefail

root=$PWD
go="$root/@@GO@@"
manifest=@@MANIFEST@@
proxy="$root/"@@PROXY@@

work="$TEST_TMPDIR/work"
mod="$work/mod"
mkdir -p "$mod" "$work/home"
# Real copies: the go command reads the module tree and Bazel's runfiles are
# symlinks.
while IFS=$'\t' read -r src dest; do
  mkdir -p "$mod/$(dirname "$dest")"
  cp "$src" "$mod/$dest"
done <"$manifest"

goroot=$(dirname "$(dirname "$go")")
export GOROOT=$goroot
export PATH="$goroot/bin:$PATH"
export HOME="$work/home"
export GOCACHE="$work/gocache"
export GOPATH="$work/gopath"
export GOMODCACHE="$work/gopath/pkg/mod"
export GOPROXY="file://$proxy"
# go.sum is what is checked; the checksum database is not consulted.
export GOSUMDB=off
# -modcacherw: Bazel deletes TEST_TMPDIR, module cache included.
export GOFLAGS="-mod=mod -modcacherw"
export GOTOOLCHAIN=local
export GOWORK=off
export GOTELEMETRY=off

cd "$mod"
status=0
"$go" mod tidy -diff || status=$?
if ((status != 0)); then
  echo "go_mod_tidy_test: FAIL: go mod tidy -diff exited $status: go.mod or go.sum is not tidy (a diff above) or a module does not match go.sum" >&2
  exit 1
fi
# The modules tidy loaded are now in the fresh cache; verify checks them
# against go.sum.
"$go" mod verify
echo "go_mod_tidy_test: ok: go.mod and go.sum are tidy, modules verified"
