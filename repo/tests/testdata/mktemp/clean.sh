#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
out=$(mktemp "${TMPDIR:-/tmp}/clean.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp}/clean.XXXXXX")
out=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/clean.XXXXXX")
work=$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/clean.XXXXXX")
