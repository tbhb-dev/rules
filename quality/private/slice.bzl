# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A mutation unit's slice of the shared change set.

A mutation runner's report rule adds MUTATION_CHANGES_ATTRS and calls
mutation_changes_slice with the files it copies. The slice keeps only the
change set's entries for those files except `diff_ignore`, and drops the
base revision, so change sets that differ only outside the unit give
byte-identical slices:
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
    "diff_ignore": attr.string_list(
        default = [],
        doc = "Repository-relative paths to omit from diff selection, as spelled in the change set. A trailing / matches every path below that directory; no other glob syntax applies. Files remain action inputs. Requires full-scope mutation elsewhere (for example, a scheduled run without a change set): only that run catches verdict changes caused by ignored files.",
    ),
    "_slice": attr.label(
        default = Label("//quality/private:slice.awk"),
        allow_single_file = True,
    ),
}

def _json_string(value):
    return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\t", "\\t")

def _ignored(path, entries):
    for entry in entries:
        if path == entry or (entry.endswith("/") and path.startswith(entry)):
            return True
    return False

def mutation_changes_slice(ctx, files):
    """Declare and write the unit's slice of the change set.

    Args:
        ctx: The rule context; the rule has MUTATION_CHANGES_ATTRS.
        files: The Files the unit's report action copies, from the main
            repository.

    Returns:
        The slice File, or None when no change set is set (a full run).
    """
    for entry in ctx.attr.diff_ignore:
        if not entry:
            fail("diff_ignore: entries must not be empty")
        if entry.startswith("/"):
            fail("diff_ignore: '{}' must be repository-relative (no leading /)".format(entry))
        if ".." in entry.split("/"):
            fail("diff_ignore: '{}' must not contain .. path segments".format(entry))
    changes = ctx.files.changes
    if not changes:
        return None
    if len(changes) != 1:
        fail("changes gives {} files; a change set is one file".format(len(changes)))

    # Ignored files remain in the caller's report inputs and scratch copy.
    # Only diff selection omits them.
    paths = ctx.actions.declare_file(ctx.label.name + ".unit_paths")
    ctx.actions.write(
        output = paths,
        content = "".join(["{}\n".format(_json_string(f.short_path)) for f in files if not _ignored(f.short_path, ctx.attr.diff_ignore)]),
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
