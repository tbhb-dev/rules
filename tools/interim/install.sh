#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Install the prek git hook shims for this clone. Idempotent; only touches this
# repository's .git/hooks, never the global config. prek refuses to install when
# core.hooksPath is set, so that case warns and stops without changing it.
set -euo pipefail

hooks_path=$(git config --get core.hooksPath || true)
if [[ -n $hooks_path ]]; then
  echo "install.sh: warning: core.hooksPath is $hooks_path; not installing prek hooks" >&2
  exit 0
fi

if command -v prek >/dev/null 2>&1; then
  prek=(prek)
elif command -v mise >/dev/null 2>&1; then
  prek=(mise exec -- prek)
else
  echo "install.sh: error: prek not found; run it through 'uv run' (prek is in the uv dev group)" >&2
  exit 1
fi

"${prek[@]}" install \
  --hook-type pre-commit \
  --hook-type prepare-commit-msg \
  --hook-type commit-msg \
  --hook-type post-commit \
  --hook-type pre-push
echo "install.sh: installed prek hooks"
