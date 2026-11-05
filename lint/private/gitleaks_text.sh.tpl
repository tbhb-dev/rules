#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Scans the text on stdin with gitleaks, under the workspace's .gitleaks.toml
# when it has one. Generated from gitleaks_text.sh.tpl; the @@NAME@@ markers
# are filled in at analysis time. Run with `bazel run`. Arguments go to
# `gitleaks stdin`.

set -euo pipefail

tool="$PWD/@@TOOL@@"

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"

# The private config extends .gitleaks.toml at the workspace root, which
# gitleaks_tool requires by that name.
args=(stdin --redact --no-banner)
if [[ -f .gitleaks.toml ]]; then
  args+=(--config .gitleaks.toml)
fi
exec "$tool" "${args[@]}" "$@"
