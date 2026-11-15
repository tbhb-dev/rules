#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Subject for the expect_failure_test tests: prints "ri", a NUL byte and "ght"
# on one line, then exits with its status from the environment. The bash
# printf builtin turns \0 into a NUL byte on macOS and Linux alike.
printf 'ri\0ght\n'
exit "${SUBJECT_STATUS:-0}"
