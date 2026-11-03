#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs go-arch-lint over a copy of a Go module. Generated from
# go_arch_lint.sh.tpl by go_arch_lint_test; the @@NAME@@ markers are filled
# in at analysis time.

set -euo pipefail

root=$PWD
tool="$root/@@TOOL@@"
manifest=@@MANIFEST@@
config=@@CONFIG@@
args=(@@ARGS@@)

ws="$TEST_TMPDIR/ws"
mkdir -p "$ws"
count=0
while IFS=$'\t' read -r src dest; do
  mkdir -p "$ws/$(dirname "$dest")"
  cp "$src" "$ws/$dest"
  if [[ $dest == *.go ]]; then
    count=$((count + 1))
  fi
done <"$manifest"
if ((count == 0)); then
  echo "go_arch_lint_test: FAIL: no Go file to check, which proves nothing" >&2
  exit 1
fi

# Deep scanning runs `go list` through go/packages; there is no go command
# here, and the import contracts do not need it.
if ! grep -Eq '^[[:space:]]+deepScan:[[:space:]]*false([[:space:]]|#|$)' "$ws/$config"; then
  echo "go_arch_lint_test: FAIL: $config must set allow.deepScan: false" >&2
  exit 1
fi

# No go command, module cache or network: if the tool reached for one, the
# run would fail rather than quietly use the host's.
export PATH=/usr/bin:/bin
export GOPROXY=off
export GOFLAGS=-mod=mod
export GOTOOLCHAIN=local
export HOME="$TEST_TMPDIR/home"
export GOPATH="$TEST_TMPDIR/gopath"
export GOMODCACHE="$TEST_TMPDIR/gopath/pkg/mod"
export GOCACHE="$TEST_TMPDIR/gocache"

echo "go_arch_lint_test: checking $count Go files"
"$tool" check \
  --output-color=false \
  --project-path "$ws" \
  --arch-file "$config" \
  ${args[@]+"${args[@]}"}
