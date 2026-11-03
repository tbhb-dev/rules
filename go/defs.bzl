# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_go."""

load(
    "//private:golangci_lint.bzl",
    _GolangciLintInfo = "GolangciLintInfo",
    _golangci_lint_aspect_factory = "golangci_lint_aspect_factory",
    _golangci_lint_test_factory = "golangci_lint_test_factory",
)

GolangciLintInfo = _GolangciLintInfo
golangci_lint_aspect_factory = _golangci_lint_aspect_factory
golangci_lint_test_factory = _golangci_lint_test_factory
