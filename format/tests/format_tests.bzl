# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests for the format rules."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//format:defs.bzl", "format", "formatter")

def _expect_failure(text):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*{}*".format(text)))

    return impl

def _test_check_args_required(name):
    util.helper_target(
        formatter,
        name = name + "_subject",
        fix_args = ["-w"],
        include = ["*.sh"],
        tool = "@tbhb_rules_shfmt//:shfmt",
    )
    analysis_test(name = name, impl = _expect_failure("check_args must not be empty"), target = name + "_subject", expect_failure = True)

def _test_include_required(name):
    util.helper_target(
        formatter,
        name = name + "_subject",
        check_args = ["-d"],
        tool = "@tbhb_rules_shfmt//:shfmt",
    )
    analysis_test(name = name, impl = _expect_failure("include must name at least one pattern"), target = name + "_subject", expect_failure = True)

def _test_run_modes(name):
    format(name = name + "_subject", formatters = ["//format:shfmt"], tags = ["manual"])
    analysis_test(
        name = name,
        impl = _test_run_modes_impl,
        targets = {"check": name + "_subject.check", "fix": name + "_subject"},
    )

def _test_run_modes_impl(env, targets):
    env.expect.that_target(targets.fix).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@CALLS@@": "run_formatter '//format:shfmt' '{}' '3' '*.sh' '*.bash' '*.bats' '1' '-w'".format(
            targets.fix[DefaultInfo].default_runfiles.files.to_list()[0].short_path,
        ),
        "@@MODE@@": "fix",
        "@@SOURCE@@": "workspace",
    })
    env.expect.that_target(targets.check).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@MODE@@": "check",
        "@@SOURCE@@": "workspace",
    })

def format_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_check_args_required,
            _test_include_required,
            _test_run_modes,
        ],
    )
