# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API for quality gates."""

load(
    "//quality/private:mutation_gate.bzl",
    _MutationReportInfo = "MutationReportInfo",
    _mutation_gate_test = "mutation_gate_test",
)

MutationReportInfo = _MutationReportInfo
mutation_gate_test = _mutation_gate_test
