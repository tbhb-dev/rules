#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs one tool of the locked Python environment with the interpreter uv
# installed, its site-packages and the workspace members' source roots.
# Generated from launch.sh.tpl by python_tool; the @@NAME@@ markers are
# filled in at analysis time. It runs from the current directory, which is
# the root of a test's copy of the tree or of the workspace.

set -euo pipefail

# The runfiles root, found from this script's own path when it has its own
# runfiles (an action's tool, `bazel run`), else from the runfiles Bazel names
# in the environment (tests and the runners they start), else from the path
# it was called by ("$runfiles/<short path>"). The environment comes before
# the calling path: reached through a PATH symlink, a root-package tool's
# short path is just its name and would match the symlink's directory.
self=@@SELF@@
if [[ -d "$0.runfiles/_main" ]]; then
  base="$0.runfiles/_main"
elif [[ -n ${RUNFILES_DIR:-} ]]; then
  base="$RUNFILES_DIR/_main"
elif [[ -n ${TEST_SRCDIR:-} ]]; then
  base="$TEST_SRCDIR/_main"
elif [[ $0 == *"/$self" ]]; then
  base=${0%"/$self"}
else
  echo "python_tool: cannot find the runfiles of $0" >&2
  exit 1
fi
# On Windows the interpreter is a native program: what it reads gets
# C:/... paths (pwd -W) and ;-separated lists. Bash's own PATH keeps POSIX
# paths (posix), which MSYS converts for the programs it starts, and
# carries the interpreter's and uv's own directories: ln -s there copies a
# file, and python.exe needs the DLLs beside it.
windows=@@WINDOWS@@
posix=$(cd "$base" && pwd)
if [[ -n $windows ]]; then
  base=$(cd "$base" && pwd -W)
  here=$(pwd -W)
  sep=";"
else
  base=$posix
  here=$PWD
  sep=":"
fi

interpreter="$base/@@INTERPRETER@@"
export TBHB_PYTHON_SITE_PACKAGES="$base/@@SITE_PACKAGES@@"
export TBHB_PYTHON_BIN="$base/@@BIN@@"
export TBHB_PYTHON_UV="$base/@@UV@@"

# Workspace members' source roots, relative to the tree root (the current
# directory), so a test sees the copy and the formatter the workspace.
pythonpath="$base/@@BOOT@@"
source_roots=(@@SOURCE_ROOTS@@)
for root in ${source_roots[@]+"${source_roots[@]}"}; do
  pythonpath+="$sep$here/$root"
done
export PYTHONPATH="$pythonpath"
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
unset PYTHONHOME PYTHONSTARTUP VIRTUAL_ENV

# As under `uv run`, the environment's executables come first on PATH, and
# tools that look for an interpreter there (pyrefly asks it for sys.path)
# find this one.
if [[ -n $windows ]]; then
  PATH="$(dirname "$posix/@@INTERPRETER@@"):$(dirname "$posix/@@UV@@"):$posix/@@BIN@@:$PATH"
  export PATH
else
  shims=$(mktemp -d "${TMPDIR:-/tmp}/launch.XXXXXX")
  trap 'rm -rf "$shims"' EXIT
  ln -s "$interpreter" "$shims/python"
  ln -s "$interpreter" "$shims/python3"
  ln -s "$TBHB_PYTHON_UV" "$shims/uv"
  export PATH="$shims:$TBHB_PYTHON_BIN:$PATH"
fi
# A `uv run` inside the tool (a git hook, a script) runs the pinned uv
# (shimmed above) with this interpreter and its packages rather than
# downloading one: uv's managed installs live under a HOME the test does
# not share.
export UV_PYTHON="$interpreter" UV_PYTHON_DOWNLOADS=never

status=0
"$interpreter" "$base/@@LAUNCH@@" @@OPTIONS@@ -- @@TOOL@@ "$@" || status=$?
exit "$status"
