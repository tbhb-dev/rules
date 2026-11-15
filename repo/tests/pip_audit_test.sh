#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

set -euo pipefail
workflow=${TEST_SRCDIR:?}/${WORKFLOW_RLOCATIONPATH:?}
audit=$(awk '
  /^      - name:/ { audit = /Audit the locked Python dependencies$/ }
  audit { print }
' "$workflow")
# Only pull requests may tolerate audit failures; pushes and schedules fail.
# shellcheck disable=SC2016
if ! grep -qxF '        continue-on-error: ${{ github.event_name == '\''pull_request'\'' }}' <<<"$audit"; then
  echo 'FAIL: pip-audit must tolerate failures only on pull_request' >&2
  exit 1
fi
echo 'PASS: pip-audit failures are non-blocking only on pull_request'
