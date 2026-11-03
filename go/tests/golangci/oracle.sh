#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# The parity oracle: runs golangci-lint the ordinary way, with the go command
# loading packages, over a copy of a Go module, and writes a findings report
# in the aspect's format. Sandboxed and offline, as afakt's vendor-mode gate:
# vendored modules only (-mod=vendor when vendor/ exists), no proxy, no
# toolchain switch, empty caches.
#
# Usage: oracle.sh GOLANGCI_LINT REPORT GO MODULE_DIR CONFIG FILES OUT [PROXY]
#
# PROXY, when given, is a go_mod_proxy directory: modules come from it, as
# GOPROXY=file://..., instead of from vendor/.
# FILES lists the module's files, the config among them, as exec paths under
# MODULE_DIR; CONFIG is one of them.

set -euo pipefail

golangci_lint=$1
report=$2
go=$3
module_dir=$4
config=$5
files=$6
out=$7
proxy=${8:-}

root=$(pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
mod="$tmp/mod"
mkdir -p "$mod" "$tmp/home"
while IFS= read -r f; do
  rel=${f#"$module_dir"/}
  mkdir -p "$mod/$(dirname "$rel")"
  cp "$f" "$mod/$rel"
done <"$files"

goroot=$(dirname "$(dirname "$root/$go")")
export GOROOT=$goroot
export PATH="$goroot/bin:$PATH"
export HOME="$tmp/home"
export TMPDIR="$tmp"
export GOCACHE="$tmp/gocache"
export GOLANGCI_LINT_CACHE="$tmp/golangci-lint"
export GOPATH="$tmp/gopath"
export GOMODCACHE="$tmp/gopath/pkg/mod"
export GOPROXY=off
if [[ -n $proxy ]]; then
  export GOPROXY="file://$root/$proxy"
  export GOSUMDB=off
fi
export GOTOOLCHAIN=local
export GOWORK=off
export GOTELEMETRY=off
# -modcacherw: the module cache is deleted with the rest at exit.
export GOFLAGS="-mod=mod -modcacherw"
if [[ -d "$mod/vendor" ]]; then
  export GOFLAGS="-mod=vendor -modcacherw"
fi
# Pure Go, so the oracle needs no C toolchain.
export CGO_ENABLED=0

status=0
(
  cd "$mod"
  "$root/$golangci_lint" run \
    --config "$mod/${config#"$module_dir"/}" \
    --path-mode=abs \
    --show-stats=false \
    --output.json.path="$tmp/issues.json" \
    ./...
) >"$tmp/log" 2>&1 || status=$?

"$root/$report" \
  -in "$tmp/issues.json" \
  -exit "$status" \
  -log "$tmp/log" \
  -base "$mod" \
  -out "$root/$out"
