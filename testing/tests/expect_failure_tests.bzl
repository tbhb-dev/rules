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

def _test_wraps_executable_and_env(name):
    util.helper_target(
        expect_failure_test,
        name = name + "_subject",
        pattern = "x",
        test = ":fails_for_the_right_reason",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_wraps_executable_and_env_impl, target = name + "_subject")

def _test_wraps_executable_and_env_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@PATTERN@@": "'x'",
        "@@TEST@@": "testing/tests/fails_for_the_right_reason",
    })
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
            _test_wraps_executable_and_env,
        ],
    )
