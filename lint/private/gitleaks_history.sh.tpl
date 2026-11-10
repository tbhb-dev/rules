#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Scans the workspace's git history with gitleaks. Generated from
# gitleaks_history.sh.tpl; the @@NAME@@ markers are filled in at analysis
# time. Run with `bazel run`. A shallow clone scans only the commits it has.
# Arguments go to `gitleaks git` before the path, so `--log-opts=HEAD` limits
# the scan to the checked-out branch; without it gitleaks scans every ref.
# A leading --merge-range selects a pull request merge commit's own history
# when HEAD matches EXPECTED_HEAD, falling back to HEAD on any uncertainty.

set -euo pipefail

runfiles=$PWD
tool="$runfiles/@@TOOL@@"
git_dir="$runfiles/@@GIT_DIR@@"
config=@@CONFIG@@

export PATH="$git_dir:$PATH"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

cd "${BUILD_WORKSPACE_DIRECTORY:?run this target with bazel run}"

if ! git rev-parse --verify --quiet HEAD >/dev/null; then
  echo "gitleaks_history: FAIL: the repository has no commits to scan" >&2
  exit 1
fi

if [[ ${1:-} == --merge-range ]]; then
  shift
  scan_range=HEAD
  reason="HEAD does not have exactly two readable parents"
  if [[ -z ${EXPECTED_HEAD:-} ]]; then
    reason="EXPECTED_HEAD is unset"
  elif ! head=$(git rev-parse --verify --quiet HEAD); then
    reason="git could not resolve HEAD"
  elif [[ $head != "$EXPECTED_HEAD" ]]; then
    reason="HEAD is not the commit the event names"
  elif git rev-parse --verify --quiet HEAD^1 >/dev/null &&
    git rev-parse --verify --quiet HEAD^2 >/dev/null &&
    parents=$(git show -s --format=%P HEAD) &&
    [[ $parents =~ ^[0-9a-f]+\ [0-9a-f]+$ ]]; then
    if changed=$(git diff --name-only HEAD^1 HEAD); then
      if grep -Fxq '.gitleaks.toml' <<<"$changed"; then
        reason="the pull request changes .gitleaks.toml"
      elif grep -Fxq '.gitleaksignore' <<<"$changed"; then
        reason="the pull request changes .gitleaksignore"
      else
        scan_range=HEAD^1..HEAD
        reason="the pull request's commits"
      fi
    else
      reason="git could not compare the merge commit with its first parent"
    fi
  fi
  if ! count=$(git rev-list --count "$scan_range") || [[ ! $count =~ ^[0-9]+$ ]]; then
    scan_range=HEAD
    reason="git could not count the selected history"
    count=$(git rev-list --count HEAD) || count=unknown
    [[ $count =~ ^[0-9]+$ ]] || count=unknown
  fi
  if [[ $scan_range == HEAD ]]; then
    echo "gitleaks_history: scanning full history HEAD ($count commits): $reason"
  else
    echo "gitleaks_history: scanning $scan_range ($count commits): $reason"
  fi
  # Put the selected range last so forwarded flags cannot override it.
  set -- "$@" "--log-opts=$scan_range"
fi

args=(git --verbose --redact --no-banner)
if [[ -n $config ]]; then
  args+=(--config "$config")
fi

log=$(mktemp)
history=$(mktemp)
trap 'rm -f "$log" "$history"' EXIT
# To a file, not a pipe, so gitleaks' own exit status survives.
status=0
"$tool" "${args[@]}" "$@" . >"$log" 2>&1 || status=$?
cat "$log"
if ((status != 0)); then
  exit "$status"
fi

# gitleaks exits 0 when its git invocation fails, after scanning nothing.
if ! grep -Eq '[1-9][0-9]* commits scanned' "$log"; then
  if ! git log -p --format= "${scan_range:-HEAD}" >"$history"; then
    echo "gitleaks_history: FAIL: git cannot read the history that gitleaks scanned 0 commits of" >&2
    exit 1
  fi
  if grep -Eq '^[+-]' "$history"; then
    echo "gitleaks_history: FAIL: gitleaks scanned 0 commits of a history with content, which proves nothing" >&2
    exit 1
  fi
  echo "gitleaks_history: the history holds no content to scan"
fi
