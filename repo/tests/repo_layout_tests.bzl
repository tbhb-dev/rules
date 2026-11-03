# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests for repo_layout_test's argument checks."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//repo:defs.bzl", "repo_layout_test")

def scripts_layout_test(name, fixture, **kwargs):
    """A layout whose tools/ holds uv scripts, plus tools/interim/, over a fixture tree."""
    repo_layout_test(
        name = name,
        srcs = native.glob(["testdata/layout/{}/**".format(fixture)]) if fixture else [],
        strip_prefix = "repo/tests/testdata/layout/" + fixture if fixture else "",
        allowed_subdirs = {"tools": ["interim"]},
        scripts = {"tools": "pep723"},
        top_level_dirs = [
            "docs",
            "tools",
        ],
        **kwargs
    )

def _failure_test(name, message, **attrs):
    util.helper_target(
        repo_layout_test,
        name = name + "_subject",
        srcs = ["testdata/layout/good/README.md"],
        tags = ["manual"],
        **attrs
    )

    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*{}*".format(message)))

    analysis_test(name = name, impl = impl, target = name + "_subject", expect_failure = True)

def _test_no_top_level_dirs(name):
    _failure_test(name, "top_level_dirs must name at least one directory", top_level_dirs = [])

def _test_nested_top_level_dir(name):
    _failure_test(name, "must be a single directory name", top_level_dirs = ["tools/interim"])

def _test_script_dir_not_top_level(name):
    _failure_test(name, "scripts names bin, which is not in top_level_dirs", scripts = {"bin": "pep723"}, top_level_dirs = ["tools"])

def _test_unknown_script_kind(name):
    _failure_test(name, "the kinds are", scripts = {"tools": "python"}, top_level_dirs = ["tools"])

def _test_subdirs_without_scripts(name):
    _failure_test(name, "allowed_subdirs names tools, which is not a scripts directory", allowed_subdirs = {"tools": ["interim"]}, top_level_dirs = ["tools"])

def repo_layout_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_no_top_level_dirs,
            _test_nested_top_level_dir,
            _test_script_dir_not_top_level,
            _test_unknown_script_kind,
            _test_subdirs_without_scripts,
        ],
    )
