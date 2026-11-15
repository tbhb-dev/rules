#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runfiles are symlinks into the source tree, and the check rejects symlinks
# that leave the repository root. Copy the fixture so the check sees real files.
# Usage: required_files_case.sh MANIFEST SCHEMA FIXTURE
set -euo pipefail

work=$(mktemp -d "${TEST_TMPDIR:?}/fixture.XXXXXX")
cp -RL "$3" "$work/repo"
exec repo/tests/check_required_files "$1" "$2" "$work/repo"
