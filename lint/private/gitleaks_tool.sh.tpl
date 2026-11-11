#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Every scanner and the bazel_env shim enter through this policy wrapper.
set -euo pipefail

self=@@SELF@@
if [[ -d "$0.runfiles/_main" ]]; then
  root="$0.runfiles/_main"
elif [[ -n ${RUNFILES_DIR:-} ]]; then
  root="$RUNFILES_DIR/_main"
elif [[ -n ${TEST_SRCDIR:-} ]]; then
  root="$TEST_SRCDIR/_main"
else
  root=${0%"/$self"}
fi
if [[ $root == "$0" ]]; then
  echo "gitleaks_tool: FAIL: cannot find the runfiles of $0" >&2
  exit 1
fi
# Keep absolute paths before callers move into a scratch tree or workspace.
root=$(cd "$root" && pwd)
gitleaks="$root/@@GITLEAKS@@"
base="$root/@@BASE@@"
prepare="$root/@@PREPARE@@"
required=@@REQUIRED@@

fail() {
  echo "gitleaks_tool: FAIL: $*" >&2
  exit 1
}

if [[ -n $required ]]; then
  if [[ -z ${GITLEAKS_CONFIG_TOML:-} ]]; then
    fail "GITLEAKS_CONFIG_TOML is unset or empty. @tbhb_rules//lint:gitleaks_private_config" \
      "requires the private gitleaks config in it."
  fi
  canary='^[[:space:]]*id[[:space:]]*=[[:space:]]*["'\'']tbhb-private-canary["'\''][[:space:]]*(#.*)?$'
  if ! grep -Eq "$canary" <<<"$GITLEAKS_CONFIG_TOML"; then
    fail "the config in GITLEAKS_CONFIG_TOML has no rule with the id" \
      "tbhb-private-canary, so it isn't the private config."
  fi
fi

args=()
committed=
while (($# > 0)); do
  case $1 in
  --)
    args+=("$@")
    break
    ;;
  --config | -c)
    (($# > 1)) || fail "--config has no value"
    [[ -z $committed ]] || fail "--config is given more than once"
    committed=$2
    shift 2
    ;;
  --config=*)
    [[ -z $committed ]] || fail "--config is given more than once"
    committed=${1#--config=}
    [[ -n $committed ]] || fail "--config has no value"
    shift
    ;;
  *)
    args+=("$1")
    shift
    ;;
  esac
done
if [[ -n $required && $committed != .gitleaks.toml ]]; then
  fail "the private config extends .gitleaks.toml at the scan root, but the" \
    "committed config is '${committed:-unset}'. Name .gitleaks.toml at the" \
    "repository root as the config."
fi
if [[ -z $committed && -f .gitleaks.toml ]]; then
  committed=.gitleaks.toml
fi
config=$base
if [[ -n $committed ]]; then
  [[ -f $committed ]] || fail "$PWD/$committed does not exist"
  dir=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/gitleaks-private.XXXXXX")
  trap 'rm -rf -- "$dir"' EXIT
  config="$dir/effective.toml"
  if [[ -n $required ]]; then
    printf '%s\n' "$GITLEAKS_CONFIG_TOML" >"$dir/private.toml"
    config="$dir/private.toml"
  fi
  "$prepare" "$base" "$committed" "$dir"
fi
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
status=0
"$gitleaks" --config "$config" "${args[@]}" || status=$?
exit "$status"
