# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`changes_slice`: a unit's slice of a change set, for the slice proofs."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//quality:defs.bzl", "MUTATION_CHANGES_ATTRS", "mutation_changes_slice")

def _changes_slice_impl(ctx):
    out = mutation_changes_slice(ctx, ctx.files.srcs)
    if out == None:
        # No change set: the helper declares nothing, so say so in a file
        # the proofs can compare.
        out = ctx.actions.declare_file(ctx.label.name + ".none")
        ctx.actions.write(output = out, content = "no change set\n")
    return [DefaultInfo(files = depset([out]))]

changes_slice = rule(
    implementation = _changes_slice_impl,
    attrs = MUTATION_CHANGES_ATTRS | {
        "srcs": attr.label_list(allow_files = True, doc = "The unit's files."),
    },
)

def _expect_invalid_entry(message):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.str_matches("*" + message + "*"))

    return impl

def diff_ignore_failures(name):
    """Prove invalid paths fail during analysis, even without a change set.

    Args:
        name: Prefix of the analysis test targets.
    """
    for case, entry, message in [
        ("empty", "", "entries must not be empty"),
        ("absolute", "/uv.lock", "must be repository-relative (no leading /)"),
        ("parent", "packages/../uv.lock", "must not contain .. path segments"),
        ("parent_first", "../uv.lock", "must not contain .. path segments"),
        ("parent_last", "packages/..", "must not contain .. path segments"),
    ]:
        subject = name + "_" + case + "_subject"
        util.helper_target(changes_slice, name = subject, diff_ignore = [entry], changes = "//quality:no_changes")
        analysis_test(
            name = name + "_" + case + "_fails",
            impl = _expect_invalid_entry("diff_ignore: " + ("" if not entry else "'" + entry + "' ") + message),
            target = subject,
            expect_failure = True,
        )
