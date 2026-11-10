# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Expose the mutation report alone for the empty-selection proof."""

load("@tbhb_rules//quality:defs.bzl", "MutationReportInfo")

def _mutation_report_file_impl(ctx):
    return [DefaultInfo(files = ctx.attr.report[MutationReportInfo].reports)]

mutation_report_file = rule(
    implementation = _mutation_report_file_impl,
    attrs = {"report": attr.label(providers = [MutationReportInfo])},
)
