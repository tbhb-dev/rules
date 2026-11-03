# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_go."""

load("//private:deadcode.bzl", _go_deadcode_test = "go_deadcode_test")
load(
    "//private:golangci_lint.bzl",
    _GolangciLintInfo = "GolangciLintInfo",
    _golangci_lint_aspect_factory = "golangci_lint_aspect_factory",
    _golangci_lint_test_factory = "golangci_lint_test_factory",
)

GolangciLintInfo = _GolangciLintInfo
go_deadcode_test = _go_deadcode_test
golangci_lint_aspect_factory = _golangci_lint_aspect_factory
golangci_lint_test_factory = _golangci_lint_test_factory
