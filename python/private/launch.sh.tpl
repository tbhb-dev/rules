#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs one tool of the locked Python environment with the interpreter uv
# installed, its site-packages and the workspace members' source roots.
# Generated from launch.sh.tpl by python_tool; the @@NAME@@ markers are
# filled in at analysis time. It runs from the current directory, which is
# the root of a test's copy of the tree or of the workspace.

set -euo pipefail

# The runfiles root, found from this script's own path: beside it when run
# as an action's tool or with `bazel run`, else from the path it was called
# by (tests and the format runner call "$runfiles/<short path>").
self=@@SELF@@
if [[ -d "$0.runfiles/_main" ]]; then
  base="$0.runfiles/_main"
elif [[ $0 == *"/$self" ]]; then
  base=${0%"/$self"}
elif [[ -n ${RUNFILES_DIR:-} ]]; then
  base="$RUNFILES_DIR/_main"
else
  echo "python_tool: cannot find the runfiles of $0" >&2
  exit 1
fi
base=$(cd "$base" && pwd)

interpreter="$base/@@INTERPRETER@@"
export TBHB_PYTHON_SITE_PACKAGES="$base/@@SITE_PACKAGES@@"
export TBHB_PYTHON_BIN="$base/@@BIN@@"
export TBHB_PYTHON_UV="$base/@@UV@@"

# Workspace members' source roots, relative to the tree root (the current
# directory), so a test sees the copy and the formatter the workspace.
pythonpath="$base/@@BOOT@@"
for root in @@SOURCE_ROOTS@@; do
  pythonpath+=":$PWD/$root"
done
export PYTHONPATH="$pythonpath"
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
unset PYTHONHOME PYTHONSTARTUP VIRTUAL_ENV

# Tools that look for an interpreter on PATH (pyrefly asks it for sys.path)
# find this one.
shims=$(mktemp -d)
trap 'rm -rf "$shims"' EXIT
ln -s "$interpreter" "$shims/python"
ln -s "$interpreter" "$shims/python3"
export PATH="$shims:$PATH"

status=0
"$interpreter" "$base/@@LAUNCH@@" @@OPTIONS@@ -- @@TOOL@@ "$@" || status=$?
exit "$status"
