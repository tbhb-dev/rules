#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

shim=$1
config=$2
shift 2
base=
if [[ $1 == --base ]]; then
  base=$2
  shift 2
fi

if [[ -f $shim && -x $shim ]]; then
  exec "$shim" "$@" --config "$config"
fi

expected_version=8.30.1
found='gitleaks absent from PATH'
if binary=$(type -P gitleaks); then
  found='version command failed'
  # Keep trailing newlines so extra output cannot match the pin.
  if version=$("$binary" version 2>/dev/null && printf '.'); then
    version=${version%.}
    if [[ $version == "$expected_version" || $version == "$expected_version"$'\n' ]]; then
      if [[ -z $base ]]; then
        exec "$binary" "$@" --config "$config"
      fi

      # The root shim supplies this extension before it calls gitleaks.
      # Add it to a temporary copy when calling the PATH binary directly.
      effective=$(mktemp "${TMPDIR:-/tmp}/gitleaks-hook.XXXXXX") || exit 1
      trap 'rm -f -- "$effective"' EXIT
      { cat -- "$config" && printf '\n[extend]\npath = "%s"\n' "$base"; } >"$effective" || exit 1
      "$binary" "$@" --config "$effective"
      exit $?
    fi
    found='no version output'
    if [[ -n $version ]]; then
      printf -v found 'found version %q' "${version%$'\n'}"
    fi
  elif [[ -n $version ]]; then
    printf -v found 'version command failed with output %q' "$version"
  fi
fi

printf 'gitleaks: need executable %s or gitleaks %s on PATH (%s).\n' \
  "$shim" "$expected_version" "$found" >&2
exit 1
