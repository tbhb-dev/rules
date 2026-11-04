# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_go."""

load("//private:deadcode.bzl", _go_deadcode_test = "go_deadcode_test")
load("//private:go_arch_lint.bzl", _go_arch_lint_test = "go_arch_lint_test")
load("//private:go_mod_tidy.bzl", _go_mod_tidy_test = "go_mod_tidy_test")
load("//private:gobco.bzl", _gobco_test = "gobco_test")
load(
    "//private:golangci_lint.bzl",
    _GolangciLintInfo = "GolangciLintInfo",
    _golangci_lint_aspect_factory = "golangci_lint_aspect_factory",
    _golangci_lint_test_factory = "golangci_lint_test_factory",
)
load("//private:gomutants.bzl", _gomutants_report = "gomutants_report", _gomutants_test = "gomutants_test")

GolangciLintInfo = _GolangciLintInfo
go_arch_lint_test = _go_arch_lint_test
go_deadcode_test = _go_deadcode_test
go_mod_tidy_test = _go_mod_tidy_test
gobco_test = _gobco_test
golangci_lint_aspect_factory = _golangci_lint_aspect_factory
golangci_lint_test_factory = _golangci_lint_test_factory
gomutants_report = _gomutants_report
gomutants_test = _gomutants_test
