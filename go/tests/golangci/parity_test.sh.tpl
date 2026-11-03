#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Passes when the aspect's reports, merged as golangci_lint_test merges
# them, hold exactly the oracle's findings. Generated from parity_test.sh.tpl by golangci_lint_parity_test.

set -euo pipefail

manifest=@@MANIFEST@@
merge=@@MERGE@@
oracle=@@ORACLE@@
strip=@@STRIP@@

aspect_findings=$TEST_TMPDIR/aspect.txt
oracle_findings=$TEST_TMPDIR/oracle.txt

"$merge" "$manifest" | sed "s|^$strip||" | LC_ALL=C sort -u >"$aspect_findings"
LC_ALL=C sort -u "$oracle" >"$oracle_findings"

count=$(grep -c "" "$oracle_findings" || true)
echo "--- oracle findings ($count) ---"
cat "$oracle_findings"

if [[ ! -s $oracle_findings ]]; then
  echo "golangci_lint_parity_test: FAIL: the oracle found nothing; the fixture must plant findings" >&2
  exit 1
fi
if grep -q '^golangci-lint did not complete' "$oracle_findings" "$aspect_findings"; then
  echo "golangci_lint_parity_test: FAIL: a run did not complete" >&2
  cat "$aspect_findings"
  exit 1
fi
# Not diff(1): MSYS2 does not ship it.
if [[ "$(<"$oracle_findings")" != "$(<"$aspect_findings")" ]]; then
  echo "--- aspect findings ---"
  cat "$aspect_findings"
  echo "golangci_lint_parity_test: FAIL: the aspect's findings (+) differ from the oracle's (-)" >&2
  exit 1
fi
echo "golangci_lint_parity_test: ok: the aspect reports the oracle's $count findings"
