# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The repository rules behind the pinned Ansible collections.

One repository per collection holds the Galaxy tarball, fetched by URL
and sha256 from requirements.lock.json and unpacked at
`ansible_collections/<namespace>/<name>/`, the layout
ANSIBLE_COLLECTIONS_PATH expects. A hub repository gathers them, and the
checks put every collection's root on the path.
"""

load(":manifest.bzl", "manifest_errors")

# Internal: consumers use //:extensions.bzl.
visibility("//...")

# Files that would make a directory of the collection a Bazel package or
# repository of its own and cut it out of the glob below.
_BAZEL_FILES = ["BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel", "REPO.bazel"]

_COLLECTION_BUILD = """\
filegroup(
    name = "files",
    srcs = glob(["ansible_collections/**"], allow_empty = False),
    visibility = ["//visibility:public"],
)
"""

def _prune(rctx, root):
    # Starlark has no recursion or while loop: walk with a work list, which
    # each directory visited extends. A collection is far smaller than the
    # bound.
    pending = [root]
    for _ in range(1000000):
        if not pending:
            return
        directory = pending.pop()
        for child in directory.readdir():
            if child.is_dir:
                pending.append(child)
            elif child.basename in _BAZEL_FILES:
                rctx.delete(child)
    fail("{}: too many directories to prune".format(root))

def _collection_repo_impl(rctx):
    namespace, _, name = rctx.attr.collection.partition(".")
    root = "ansible_collections/{}/{}".format(namespace, name)
    rctx.download_and_extract(
        url = rctx.attr.url,
        sha256 = rctx.attr.sha256,
        output = root,
        type = "tar.gz",
    )

    # The tarball's own MANIFEST.json names the collection and its
    # dependencies, which must all be pinned too: nothing here resolves
    # them.
    manifest = json.decode(rctx.read(root + "/MANIFEST.json"))
    errors = manifest_errors(rctx.attr.collection, rctx.attr.version, manifest, rctx.attr.pinned)
    if errors:
        fail("ansible.collections: {}:\n  {}".format(rctx.attr.collection, "\n  ".join(errors)))
    _prune(rctx, rctx.path(root))
    rctx.file("BUILD.bazel", _COLLECTION_BUILD)
    return rctx.repo_metadata(reproducible = True)

collection_repo = repository_rule(
    implementation = _collection_repo_impl,
    doc = "One Galaxy collection, fetched by sha256 and unpacked at ansible_collections/<namespace>/<name>/.",
    attrs = {
        "collection": attr.string(mandatory = True, doc = "`<namespace>.<name>`."),
        "pinned": attr.string_list(doc = "Every collection the lock pins, which the dependencies must be among."),
        "sha256": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

def _collections_hub_impl(rctx):
    rctx.file("BUILD.bazel", """\
filegroup(
    name = "tree",
    srcs = {},
    visibility = ["//visibility:public"],
)
""".format(repr(["@{}//:files".format(r) for r in rctx.attr.repos])))

collections_hub = repository_rule(
    implementation = _collections_hub_impl,
    doc = "`//:tree`: every pinned collection's files, empty when none is pinned.",
    attrs = {"repos": attr.string_list(doc = "The collection repositories' apparent names.")},
)
