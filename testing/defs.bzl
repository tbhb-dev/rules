# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API for test helpers."""

load("//testing/private:expect_failure.bzl", _expect_failure_test = "expect_failure_test")

expect_failure_test = _expect_failure_test
