# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests for cspell_test."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:util.bzl", "util")
load("//lint:defs.bzl", "cspell_test")

def _test_args_guard_and_env(name):
    util.helper_target(
        cspell_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        config = "testdata/root/cfg.toml",
        strip_prefix = "lint/tests/testdata/root",
        tool = ":fake_tool.sh",
        env = {"EXTRA": "1"},
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_args_guard_and_env_impl, target = name + "_subject")

def _test_args_guard_and_env_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@OUTPUT_GUARD@@": "'Files checked: [1-9]'",
        "@@TOOL_ARGS@@": "'lint' '--no-progress' '--dot' '--config' 'cfg.toml' '**'",
    })
    env.expect.that_target(target).provider(RunEnvironmentInfo).environment().contains_exactly({
        "BAZEL_BINDIR": ".",
        "EXTRA": "1",
    })

def _test_without_config(name):
    util.helper_target(
        cspell_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tool = ":fake_tool.sh",
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_without_config_impl, target = name + "_subject")

def _test_without_config_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@TOOL_ARGS@@": "'lint' '--no-progress' '--dot' '**'",
    })

def _test_default_tool_is_the_pinned_cspell(name):
    util.helper_target(
        cspell_test,
        name = name + "_subject",
        srcs = ["testdata/root/a.txt"],
        tags = ["manual"],
    )
    analysis_test(name = name, impl = _test_default_tool_impl, target = name + "_subject")

def _test_default_tool_impl(env, target):
    env.expect.that_target(target).action_named("TemplateExpand").substitutions().contains_at_least({
        "@@TOOL@@": "lint/private/cspell/cspell_/cspell",
    })

def cspell_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_args_guard_and_env,
            _test_without_config,
            _test_default_tool_is_the_pinned_cspell,
        ],
    )
