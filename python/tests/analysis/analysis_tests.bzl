# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Mutation macro compatibility, including the unchanged Windows exclusion."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:unit_test.bzl", "unit_test")
load("@rules_testing//lib:util.bzl", "util")
load("@tbhb_rules//quality:defs.bzl", "mutation_os_constraints")
load("//:defs.bzl", "mutmut_test")

def _test_mutmut_compatibility(name):
    cases = []
    not_windows = select({
        Label("@platforms//os:windows"): [Label("@platforms//:incompatible")],
        "//conditions:default": [],
    })
    for suffix, kwargs, restriction in [
        ("default", {}, []),
        ("none", {"mutation_oses": None}, []),
        ("empty_caller", {"target_compatible_with": []}, []),
        ("caller", {"target_compatible_with": [Label("@platforms//cpu:arm64")]}, []),
        ("linux", {"mutation_oses": ["linux"]}, ["linux"]),
        ("macos", {"mutation_oses": ["macos"]}, ["macos"]),
        ("windows", {"mutation_oses": ["windows"]}, ["windows"]),
        ("empty", {"mutation_oses": []}, []),
        ("multiple", {"mutation_oses": ["linux", "macos"]}, ["linux", "macos"]),
        ("combined", {"mutation_oses": ["linux"], "target_compatible_with": [Label("@platforms//cpu:arm64")]}, ["linux"]),
        ("caller_select", {"mutation_oses": ["macos"], "target_compatible_with": not_windows}, ["macos"]),
    ]:
        subject = name + "_" + suffix
        util.helper_target(mutmut_test, name = subject, srcs = ["//:pyproject.toml"], **kwargs)
        expected = kwargs.get("target_compatible_with", []) + not_windows
        if kwargs.get("mutation_oses") != None:
            expected = expected + select(dict(
                [(Label("@platforms//os:" + os), []) for os in restriction] +
                [("//conditions:default", [Label("@platforms//:incompatible")])],
            ))
        native.filegroup(name = subject + "_expected", target_compatible_with = expected)
        expected_value = str(native.existing_rule(subject + "_expected")["target_compatible_with"])
        for target in [subject, subject + ".report", subject + ".runner"]:
            cases.append((str(native.existing_rule(target)["target_compatible_with"]), expected_value))

    def impl(env):
        for actual, expected in cases:
            env.expect.that_str(actual).equals(expected)

    unit_test(name = name, impl = impl)

def _invalid_oses_impl(_ctx):
    mutation_os_constraints(["plan9"])
    return []

_invalid_oses = rule(implementation = _invalid_oses_impl)

def _expect_bad_name(env, target):
    env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*mutation_oses: unknown OS 'plan9'; expected linux, macos, windows*"))

def _test_bad_name(name):
    util.helper_target(_invalid_oses, name = name + "_subject")
    analysis_test(name = name, impl = _expect_bad_name, target = name + "_subject", expect_failure = True)

def analysis_test_suite(name):
    test_suite(name = name, tests = [_test_mutmut_compatibility, _test_bad_name])
