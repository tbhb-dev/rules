# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`go_srcs_aspect`: the main repository's Go sources a target reaches."""

load("@rules_go//go:def.bzl", "GoArchive")

# Internal: consumers load //:defs.bzl.
visibility(["//", "//private/...", "//tests/..."])

GoSrcsInfo = provider(
    doc = "Go source files of the main repository that a target reaches through `deps` and `embed`.",
    fields = {"srcs": "depset of source Files"},
)

def _go_srcs_aspect_impl(target, ctx):
    srcs = []
    if target.label.repo_name == "" and GoArchive in target:
        srcs = [f for f in getattr(ctx.rule.files, "srcs", []) if f.is_source]
    transitive = [
        dep[GoSrcsInfo].srcs
        for attr in ("deps", "embed")
        for dep in getattr(ctx.rule.attr, attr, []) or []
        if GoSrcsInfo in dep
    ]
    return [GoSrcsInfo(srcs = depset(srcs, transitive = transitive))]

go_srcs_aspect = aspect(
    implementation = _go_srcs_aspect_impl,
    attr_aspects = ["deps", "embed"],
    doc = "Collects the main repository's Go sources over `deps` and `embed`.",
)
