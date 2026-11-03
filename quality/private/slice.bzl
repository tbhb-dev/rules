# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A mutation unit's slice of the shared change set.

A mutation runner's report rule adds MUTATION_CHANGES_ATTRS and calls
mutation_changes_slice with the files it copies. The slice keeps only the
change set's entries for those files and drops the base revision, so two
change sets that differ only outside the unit give byte-identical slices:
the report action's inputs are unchanged and it stays a cache hit.
"""

# Internal: consumers load //quality:defs.bzl.
visibility("//quality/...")

MUTATION_CHANGES_ATTRS = {
    "changes": attr.label(
        default = Label("//quality:changes"),
        allow_files = True,
        doc = "The change set (quality's `changes` flag by default). No file means a full run.",
    ),
    "_slice": attr.label(
        default = Label("//quality/private:slice.awk"),
        allow_single_file = True,
    ),
}

def _json_string(value):
    return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\t", "\\t")

def mutation_changes_slice(ctx, files):
    """Declare and write the unit's slice of the change set.

    Args:
        ctx: The rule context; the rule has MUTATION_CHANGES_ATTRS.
        files: The Files the unit's report action copies, from the main
            repository.

    Returns:
        The slice File, or None when no change set is set (a full run).
    """
    changes = ctx.files.changes
    if not changes:
        return None
    if len(changes) != 1:
        fail("changes gives {} files; a change set is one file".format(len(changes)))
    paths = ctx.actions.declare_file(ctx.label.name + ".unit_paths")
    ctx.actions.write(
        output = paths,
        content = "".join(["{}\n".format(_json_string(f.short_path)) for f in files]),
    )
    out = ctx.actions.declare_file(ctx.label.name + ".changes")
    ctx.actions.run_shell(
        inputs = [ctx.file._slice, paths, changes[0]],
        outputs = [out],
        command = 'awk -f "$1" "$2" "$3" > "$4"',
        arguments = [ctx.file._slice.path, paths.path, changes[0].path, out.path],
        mnemonic = "MutationSlice",
        progress_message = "Slicing the change set for %{label}",
    )
    return out
