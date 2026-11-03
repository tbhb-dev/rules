# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API for quality gates."""

load(
    "//quality/private:mutation_gate.bzl",
    _MutationReportInfo = "MutationReportInfo",
    _mutation_gate_test = "mutation_gate_test",
)
load(
    "//quality/private:slice.bzl",
    _MUTATION_CHANGES_ATTRS = "MUTATION_CHANGES_ATTRS",
    _mutation_changes_slice = "mutation_changes_slice",
)

MUTATION_CHANGES_ATTRS = _MUTATION_CHANGES_ATTRS
MutationReportInfo = _MutationReportInfo
mutation_changes_slice = _mutation_changes_slice
mutation_gate_test = _mutation_gate_test
