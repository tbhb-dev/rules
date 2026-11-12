# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Unit tests of the uv sync timeout retry decision."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":python_sync.bzl", "python_sync_retry")

# From a failed repository fetch; Bazel replaces the command's stderr.
_FAILURE = """\
Error in fail: tbhb_rules_python++python+tbhb_python: uv sync failed (256):
Timed out
"""
_STDERR = _FAILURE.splitlines()[-1]

def _timeout_impl(ctx):
    env = unittest.begin(ctx)
    for attempt in [1, 2]:
        decision = python_sync_retry(256, _STDERR, attempt, 3, 150)
        asserts.true(env, decision.retry)
        asserts.equals(env, "", decision.hint)
    return unittest.end(env)

_timeout_test = unittest.make(_timeout_impl)

def _exhausted_impl(ctx):
    env = unittest.begin(ctx)
    decision = python_sync_retry(256, _STDERR, 3, 3, 150)
    asserts.false(env, decision.retry)
    asserts.equals(env, "\nuv sync timed out on all 3 attempts (150 s each).\n", decision.hint)
    decision = python_sync_retry(256, _STDERR + "\n", 1, 1, 120)
    asserts.false(env, decision.retry)
    asserts.equals(env, "\nuv sync timed out on all 1 attempts (120 s each).\n", decision.hint)
    return unittest.end(env)

_exhausted_test = unittest.make(_exhausted_impl)

def _other_result_impl(ctx):
    env = unittest.begin(ctx)
    for code, stderr in [
        (0, ""),
        (0, _STDERR),
        (1, _STDERR),
        (124, _STDERR),
        (137, _STDERR),
        (256, "No such file or directory"),
        (256, "error: request Timed out"),
        (1, "Failed to build `example`"),
        (1, "incompatible with the project's Python requirement"),
    ]:
        for attempt in [1, 3]:
            decision = python_sync_retry(code, stderr, attempt, 3, 150)
            asserts.false(env, decision.retry)
            asserts.equals(env, "", decision.hint)
    return unittest.end(env)

_other_result_test = unittest.make(_other_result_impl)

def python_sync_test_suite(name):
    unittest.suite(
        name,
        _timeout_test,
        _exhausted_test,
        _other_result_test,
    )
