# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""golangci-lint for this module, as go/README.md's quickstart declares it."""

# README quickstart below, verbatim.
load("@tbhb_rules_go//:defs.bzl", "golangci_lint_aspect_factory", "golangci_lint_test_factory")

golangci_lint = golangci_lint_aspect_factory(
    config = "//:.golangci.yml",
    go_mod = "//:go.mod",
)

golangci_lint_test = golangci_lint_test_factory(golangci_lint)
