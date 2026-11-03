#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails when the merged golangci-lint reports hold a finding. Generated from
# golangci_lint_test.sh.tpl by a golangci_lint_test rule; the @@NAME@@
# markers are filled in at analysis time.

set -euo pipefail

manifest=@@MANIFEST@@
merge=@@MERGE@@

count=$(grep -c "" "$manifest" || true)
if ((count == 0)); then
  echo "golangci_lint_test: FAIL: no package was linted; srcs reach no Go target of the main repository" >&2
  exit 1
fi

findings="$TEST_TMPDIR/findings.txt"
"$merge" "$manifest" >"$findings"
if [[ -s $findings ]]; then
  cat "$findings"
  issues=$(grep -c "" "$findings")
  echo "golangci_lint_test: FAIL: golangci-lint reported $issues issues in $count linted targets" >&2
  exit 1
fi
echo "golangci_lint_test: ok: $count linted targets, no issues"
