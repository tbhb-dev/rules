# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""golangci-lint over this module's own Go code, with its own config."""

load("//:defs.bzl", "golangci_lint_aspect_factory", "golangci_lint_test_factory")

self_lint = golangci_lint_aspect_factory(
    config = Label("//:.golangci.yml"),
    go_mod = Label("//:go.mod"),
)

self_lint_test = golangci_lint_test_factory(self_lint)
