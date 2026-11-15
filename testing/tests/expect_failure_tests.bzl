# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests for expect_failure_test."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//testing:defs.bzl", "expect_failure_test")

def _expect_failure(text):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*{}*".format(text)))

    return impl

def _test_empty_pattern_fails(name):
    util.helper_target(
        expect_failure_test,
        name = name + "_subject",
        pattern = "",
        test = ":passes",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _expect_failure("pattern must not be empty"), target = name + "_subject", expect_failure = True)

def _test_negative_status_fails(name):
    _status_fails(name, -1)

def _test_large_status_fails(name):
    _status_fails(name, 256)

def _status_fails(name, status):
    util.helper_target(
        expect_failure_test,
        name = name + "_subject",
        exit_status = status,
        pattern = "x",
        test = ":passes",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _expect_failure("exit_status must be from 0 to 255, got {}".format(status)), target = name + "_subject", expect_failure = True)

def _test_zero_status_allowed(name):
    _status_allowed(name, 0)

def _test_maximum_status_allowed(name):
    _status_allowed(name, 255)

def _status_allowed(name, status):
    util.helper_target(
        expect_failure_test,
        name = name + "_subject",
        exit_status = status,
        pattern = "x",
        test = ":passes",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _status_allowed_impl(status), target = name + "_subject")

def _status_allowed_impl(status):
    def impl(env, target):
        env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
            "@@STATUS@@": str(status),
        })

    return impl

def _test_wraps_executable_and_env(name):
    util.helper_target(
        expect_failure_test,
        name = name + "_subject",
        pattern = "x",
        test = ":proof_right_reason",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_wraps_executable_and_env_impl, target = name + "_subject")

def _test_wraps_executable_and_env_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@PATTERN@@": "'x'",
    })

    # The wrapped test's executable, or its .bat launcher on Windows.
    expand = [a for a in target.actions if a.mnemonic == "TemplateExpand"][0]
    wrapped = expand.substitutions["@@TEST@@"]
    env.expect.that_bool(wrapped.removesuffix(".bat") == "testing/tests/proof_right_reason").equals(True)
    env.expect.that_target(target).runfiles().contains("_main/testing/tests/subject.sh")
    env.expect.that_target(target).provider(RunEnvironmentInfo).environment().contains_exactly({
        "SUBJECT_MESSAGE": "the right reason",
        "SUBJECT_STATUS": "3",
    })

def expect_failure_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_empty_pattern_fails,
            _test_negative_status_fails,
            _test_large_status_fails,
            _test_zero_status_allowed,
            _test_maximum_status_allowed,
            _test_wraps_executable_and_env,
        ],
    )
