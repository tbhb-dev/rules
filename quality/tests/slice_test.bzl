# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`changes_slice`: a unit's slice of a change set, for the slice proofs."""

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
