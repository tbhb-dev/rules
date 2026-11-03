#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails when the merged golangci-lint reports hold a finding, or when a Go
# file the test expects to be linted is in no report. Generated from
# golangci_lint_test.sh.tpl by a golangci_lint_test rule; the @@NAME@@
# markers are filled in at analysis time.

set -euo pipefail

manifest=@@MANIFEST@@
merge=@@MERGE@@
expected=@@EXPECTED@@
excludes=(@@EXCLUDES@@)

count=$(grep -c "" "$manifest" || true)
if ((count == 0)); then
  echo "golangci_lint_test: FAIL: no package was linted; srcs reach no Go target of the main repository" >&2
  exit 1
fi

status=0

# Every expected Go file must be covered by some report. Go itself ignores
# testdata/ and vendor/, so those never count.
covered="$TEST_TMPDIR/covered.txt"
while IFS= read -r report; do
  tail -n +2 "${report%.txt}.covers"
done <"$manifest" | LC_ALL=C sort -u >"$covered"
missing=()
while IFS= read -r file; do
  case /$file in
  */testdata/* | */vendor/*) continue ;;
  *) ;;
  esac
  skip=0
  for pattern in ${excludes[@]+"${excludes[@]}"}; do
    # Unquoted on purpose: the pattern is a glob.
    # shellcheck disable=SC2053
    if [[ $file == $pattern ]]; then
      skip=1
      break
    fi
  done
  if ((skip == 0)) && ! grep -qxF -- "$file" "$covered"; then
    missing+=("$file")
  fi
done <"$expected"
if ((${#missing[@]} > 0)); then
  printf 'not linted: %s\n' "${missing[@]}"
  echo "golangci_lint_test: FAIL: ${#missing[@]} Go files are in no linted package; add a target that reaches them to srcs, or exclude them" >&2
  status=1
fi

findings="$TEST_TMPDIR/findings.txt"
"$merge" "$manifest" >"$findings"
if [[ -s $findings ]]; then
  cat "$findings"
  issues=$(grep -c "" "$findings")
  echo "golangci_lint_test: FAIL: golangci-lint reported $issues issues in $count linted targets" >&2
  status=1
fi
if ((status == 0)); then
  echo "golangci_lint_test: ok: $count linted targets, no issues"
fi
exit "$status"
