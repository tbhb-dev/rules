# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The golangci-lint aspect, test and parity test over the parity fixture's config."""

load("//:defs.bzl", "golangci_lint_aspect_factory", "golangci_lint_test_factory")
load(":oracle.bzl", "golangci_lint_parity_test_factory")

fixture_lint = golangci_lint_aspect_factory(
    config = Label("//tests/golangci/fixture:.golangci.yml"),
    go_mod = Label("//tests/golangci/fixture:go.mod"),
)

fixture_lint_test = golangci_lint_test_factory(fixture_lint)

# A config golangci-lint rejects, for the proof that a run that does not
# complete fails the test.
broken_lint = golangci_lint_aspect_factory(
    config = Label("//tests/golangci/broken:.golangci.yml"),
)

broken_lint_test = golangci_lint_test_factory(broken_lint)

golangci_lint_parity_test = golangci_lint_parity_test_factory(fixture_lint)

# Not given the go.mod beside the config, which must therefore stay unread.
outside_lint = golangci_lint_aspect_factory(
    config = Label("//tests/golangci/outside:.golangci.yml"),
)

outside_lint_test = golangci_lint_test_factory(outside_lint)

outside_parity_test = golangci_lint_parity_test_factory(outside_lint)
