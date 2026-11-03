# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`python_library`: a unit of first-party Python and what it depends on."""

# Internal: consumers load //:defs.bzl.
visibility("//...")

PyUnitInfo = provider(
    doc = "The first-party files of a python_library and of its transitive deps.",
    fields = {"transitive_files": "depset of the files."},
)

def _python_library_impl(ctx):
    files = depset(
        ctx.files.srcs + ctx.files.data,
        transitive = [dep[PyUnitInfo].transitive_files for dep in ctx.attr.deps],
    )
    return [DefaultInfo(files = files), PyUnitInfo(transitive_files = files)]

python_library = rule(
    implementation = _python_library_impl,
    doc = """A unit of first-party Python: its sources, data and first-party deps.

Nothing is built. The target's files are its own and, transitively, its
deps', so a mutmut_test or pytest_test over it reruns exactly when one of
them changes: Bazel's dependency graph decides what a change affects. Declare
deps as the code imports them (one unit per uv workspace member or package).""",
    attrs = {
        "data": attr.label_list(allow_files = True, doc = "Files the code or its tests read."),
        "deps": attr.label_list(providers = [PyUnitInfo], doc = "First-party units this one imports."),
        "srcs": attr.label_list(allow_files = True, doc = "The unit's Python files, tests among them."),
    },
)
