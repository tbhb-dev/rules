#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Fails when a check's report, written by a build action, is not empty.
# Generated from report_test.sh.tpl; the @@NAME@@ markers are filled in at
# analysis time.

set -euo pipefail

report=@@REPORT@@

if [[ -s $report ]]; then
  cat "$report"
  findings=$(grep -c "" "$report")
  echo "FAIL: $findings findings" >&2
  exit 1
fi
echo "ok: no findings"
