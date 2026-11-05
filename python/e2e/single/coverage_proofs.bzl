# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests of pytest_test's required `coverage` argument and its environment."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("@tbhb_rules_python//:defs.bzl", "pytest_test")

def _fails_naming_coverage(env, target):
    env.expect.that_target(target).failures().contains_predicate(
        matching.str_matches("*pytest_test needs `coverage`*coverage = None*"),
    )

def _analyses(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)

def _inherits_xdist_workers(env, target):
    inherited = target[RunEnvironmentInfo].inherited_environment
    env.expect.that_collection(inherited).contains_exactly(["CALLER_VAR", "PYTEST_XDIST_AUTO_NUM_WORKERS"])

def pytest_coverage_proofs(name, srcs):
    """Proves pytest_test's `coverage` rules and its inherited environment.

    Args:
        name: Prefix of the analysis tests.
        srcs: The files the planted pytest_test targets copy.
    """

    # Planted: nothing to measure, and no opt-out.
    util.helper_target(pytest_test, name = name + "_omitted_subject", srcs = srcs)
    analysis_test(
        name = name + "_omitted_fails",
        impl = _fails_naming_coverage,
        target = name + "_omitted_subject",
        expect_failure = True,
    )

    # The explicit opt-out analyses.
    util.helper_target(pytest_test, name = name + "_none_subject", srcs = srcs, coverage = None)
    analysis_test(
        name = name + "_none_analyses",
        impl = _analyses,
        target = name + "_none_subject",
    )

    # The xdist worker count reaches the test, next to the caller's own
    # env_inherit.
    util.helper_target(
        pytest_test,
        name = name + "_env_subject",
        srcs = srcs,
        coverage = ["tools"],
        env_inherit = ["CALLER_VAR"],
    )
    analysis_test(
        name = name + "_inherits_xdist_workers",
        impl = _inherits_xdist_workers,
        target = name + "_env_subject",
    )
