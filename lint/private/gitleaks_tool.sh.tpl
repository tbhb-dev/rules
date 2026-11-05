#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# gitleaks behind the private-config check. Generated from
# gitleaks_tool.sh.tpl; the @@NAME@@ markers are filled in at analysis time.
# Its callers start it by its runfiles path, so the runfiles root is that
# path less this script's own short path.

set -euo pipefail

self=@@SELF@@
root=${0%"/$self"}
if [[ $root == "$0" ]]; then
  echo "gitleaks_tool: FAIL: started as $0, not by its runfiles path" >&2
  exit 1
fi
gitleaks="$root/@@GITLEAKS@@"
required=@@REQUIRED@@

if [[ -z $required ]]; then
  exec "$gitleaks" "$@"
fi

fail() {
  echo "gitleaks_tool: FAIL: $*" >&2
  exit 1
}

if [[ -z ${GITLEAKS_CONFIG_TOML:-} ]]; then
  fail "GITLEAKS_CONFIG_TOML is unset or empty. @tbhb_rules//lint:gitleaks_private_config" \
    "requires the private gitleaks config in it."
fi
canary='^[[:space:]]*id[[:space:]]*=[[:space:]]*["'\'']tbhb-private-canary["'\''][[:space:]]*(#.*)?$'
if ! grep -Eq "$canary" <<<"$GITLEAKS_CONFIG_TOML"; then
  fail "the config in GITLEAKS_CONFIG_TOML has no rule with the id" \
    "tbhb-private-canary, so it isn't the private config."
fi

# The caller names the committed config with --config; the private one
# takes its place and reaches it through [extend].
args=()
committed=
while (($# > 0)); do
  if [[ $1 == --config ]]; then
    (($# > 1)) || fail "--config has no value"
    [[ -z $committed ]] || fail "--config is given more than once"
    committed=$2
    shift 2
    continue
  fi
  args+=("$1")
  shift
done
if [[ $committed != .gitleaks.toml ]]; then
  fail "the private config extends .gitleaks.toml at the scan root, but the" \
    "committed config is '${committed:-unset}'. Name .gitleaks.toml at the" \
    "repository root as the config."
fi
[[ -f $committed ]] || fail "$PWD/.gitleaks.toml does not exist"

dir=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/gitleaks-private.XXXXXX")
trap 'rm -rf -- "$dir"' EXIT
printf '%s\n' "$GITLEAKS_CONFIG_TOML" >"$dir/private.toml"
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML

status=0
"$gitleaks" "${args[@]}" --config "$dir/private.toml" || status=$?
exit "$status"
