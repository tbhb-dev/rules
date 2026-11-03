# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Analysis tests: which targets the golangci-lint aspect lints, and the
rules' validation."""

load("@rules_go//go:def.bzl", "go_binary")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//:defs.bzl", "GolangciLintInfo", "go_deadcode_test", "go_mod_tidy_test", "golangci_lint_aspect_factory")
load("//tests/golangci:linters.bzl", "fixture_lint")

FIXTURE = "//tests/golangci/fixture"

tests_only_lint = golangci_lint_aspect_factory(
    config = Label("//tests/golangci/fixture:.golangci.yml"),
    rule_kinds = ["go_test"],
)

def _reports_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [t[GolangciLintInfo].reports for t in ctx.attr.deps]))]

def _reports_rule(aspect):
    return rule(
        implementation = _reports_impl,
        attrs = {"deps": attr.label_list(aspects = [aspect])},
    )

# The reports an aspect makes for `deps`, as default outputs.
fixture_reports = _reports_rule(fixture_lint)
tests_only_reports = _reports_rule(tests_only_lint)

def _report_files(*names):
    predicates = []
    for name in names:
        predicates.append(matching.str_matches("*/{}.golangci-lint-*.txt".format(name)))
        predicates.append(matching.str_matches("*/{}.golangci-lint-*.covers".format(name)))
    return predicates

def _expect_reports(*names):
    def impl(env, target):
        paths = [f.short_path for f in target[DefaultInfo].files.to_list()]
        env.expect.that_collection(paths).contains_exactly_predicates(_report_files(*names))

    return impl

def _test_library(name):
    util.helper_target(fixture_reports, name = name + "_subject", deps = [FIXTURE + "/clean"])
    analysis_test(name = name, impl = _expect_reports("clean"), target = name + "_subject")

def _test_follows_deps_and_embed(name):
    util.helper_target(fixture_reports, name = name + "_subject", deps = [FIXTURE + "/b:b_test"], testonly = True)
    analysis_test(name = name, impl = _expect_reports("a", "b", "b_test"), target = name + "_subject")

def _test_binary_without_sources(name):
    # A binary that only embeds a library has nothing of its own to lint.
    util.helper_target(
        go_binary,
        name = name + "_binary",
        embed = [FIXTURE + "/clean"],
        tags = ["manual"],
    )
    util.helper_target(fixture_reports, name = name + "_subject", deps = [":" + name + "_binary"])
    analysis_test(name = name, impl = _expect_reports("clean"), target = name + "_subject")

def _test_rule_kinds(name):
    util.helper_target(tests_only_reports, name = name + "_subject", deps = [FIXTURE + "/b:b_test"], testonly = True)
    analysis_test(name = name, impl = _expect_reports("b_test"), target = name + "_subject")

def _expect_failure(text):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*{}*".format(text)))

    return impl

def _test_deadcode_without_go_targets(name):
    util.helper_target(
        go_deadcode_test,
        name = name + "_subject",
        srcs = [FIXTURE + ":repo_files"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _expect_failure("srcs reach no Go package of the main repository"),
        target = name + "_subject",
        expect_failure = True,
    )

def _test_tidy_source_outside_module(name):
    util.helper_target(
        go_mod_tidy_test,
        name = name + "_subject",
        srcs = ["//tests/gomod/untidy:main.go"],
        go_mod = "//tests/gomod/tidy:go.mod",
        go_sum = "//tests/gomod/tidy:go.sum",
        proxy = "@gomod_fixture_proxy//:proxy",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _expect_failure("tests/gomod/untidy/main.go is not in the module directory tests/gomod/tidy/"),
        target = name + "_subject",
        expect_failure = True,
    )

def _test_tidy_proxy_not_a_proxy(name):
    util.helper_target(
        go_mod_tidy_test,
        name = name + "_subject",
        srcs = ["//tests/gomod/tidy:main.go"],
        go_mod = "//tests/gomod/tidy:go.mod",
        go_sum = "//tests/gomod/tidy:go.sum",
        proxy = "//tests/gomod/tidy:go.sum",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _expect_failure("proxy must be a go_mod_proxy repository's :proxy target"),
        target = name + "_subject",
        expect_failure = True,
    )

def analysis_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_binary_without_sources,
            _test_deadcode_without_go_targets,
            _test_follows_deps_and_embed,
            _test_library,
            _test_rule_kinds,
            _test_tidy_proxy_not_a_proxy,
            _test_tidy_source_outside_module,
        ],
    )
