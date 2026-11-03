#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Subject for the expect_failure_test tests: prints its message and exits
# with its status, both from the environment.
echo "${SUBJECT_MESSAGE:-}"
echo "TEST_TMPDIR=$TEST_TMPDIR"
exit "${SUBJECT_STATUS:-0}"
