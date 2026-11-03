#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Tests the Bazel workspace in the current directory with the preset's ci
# config. Fetching needs the network, which fails now and then (go.dev's
# release list once returned 503s for longer than Bazel's own download
# retries waited), so the fetch alone is retried after a pause; the tests
# then run once, and a failing test is never retried here.

set -euo pipefail

attempts=3
for ((attempt = 1; ; attempt++)); do
  if bazelisk fetch --config=ci //...; then
    break
  fi
  if ((attempt == attempts)); then
    echo "test-workspace: fetch failed ${attempts} times" >&2
    exit 1
  fi
  echo "test-workspace: fetch failed (attempt ${attempt}); retrying in 60s" >&2
  sleep 60
done

exec bazelisk test --config=ci //...
