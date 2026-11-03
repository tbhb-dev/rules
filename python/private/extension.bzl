# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The `python` module extension: the root module's uv project or workspace."""

load("@tbhb_rules//runtime:defs.bzl", "python_env_repo")

# Internal: consumers use //:extensions.bzl.
visibility("//...")

_project = tag_class(
    doc = "The root module's uv project or workspace.",
    attrs = {
        "lock": attr.label(doc = "The committed uv.lock; defaults to the root module's //:uv.lock."),
        "pyproject": attr.label(doc = "The root pyproject.toml; defaults to the root module's //:pyproject.toml."),
        "python_version": attr.string(doc = "Overrides .python-version."),
    },
)

def _python_impl(mctx):
    projects = []
    for mod in mctx.modules:
        if mod.tags.project and not mod.is_root:
            fail("python.project: only the root module may declare the project, not {}".format(mod.name))
        projects.extend(mod.tags.project)
    if len(projects) > 1:
        fail("python.project: declare one project; a uv workspace is one project")
    if projects:
        project = projects[0]
        python_env_repo(
            name = "tbhb_python",
            lock = project.lock or Label("@@//:uv.lock"),
            pyproject = project.pyproject or Label("@@//:pyproject.toml"),
            python_version = project.python_version,
        )
    else:
        python_env_repo(name = "tbhb_python")

    # This module's own tool pins, for checks that analyse the consumer's
    # sources without importing its dependencies.
    python_env_repo(
        name = "tbhb_python_tools",
        lock = Label("//tools:uv.lock"),
        pyproject = Label("//tools:pyproject.toml"),
    )

    # Both are functions of committed locks (uv verifies every download
    # against their hashes), so nothing goes into MODULE.bazel.lock.
    return mctx.extension_metadata(reproducible = True)

python = module_extension(
    implementation = _python_impl,
    doc = "Builds @tbhb_python from the root module's uv project, and @tbhb_python_tools from this module's own pins.",
    tag_classes = {"project": _project},
)
