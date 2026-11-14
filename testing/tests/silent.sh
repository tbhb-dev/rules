#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Subject for the expect_failure_test tests: prints nothing and exits with
# its status from the environment.
exit "${SUBJECT_STATUS:-0}"
