# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The `ansible` module extension: the Ansible environment and the pinned collections."""

load("@tbhb_rules//runtime:defs.bzl", "python_env_repo")
load(":collections.bzl", "collection_repo", "collections_hub")

# Internal: consumers use //:extensions.bzl.
visibility("//...")

_toolchain = tag_class(
    doc = """A uv project, in any package of the root module, whose locked
environment provides ansible-core (and ansible-lint and molecule for those
checks). Its .python-version picks the interpreter unless `python_version`
overrides it.""",
    attrs = {
        "lock": attr.label(mandatory = True, doc = "The project's committed uv.lock."),
        "pyproject": attr.label(mandatory = True, doc = "The project's pyproject.toml."),
        "python_version": attr.string(doc = "Overrides the .python-version next to `pyproject`."),
    },
)

_collections = tag_class(
    doc = """The Galaxy collections the checks put on ANSIBLE_COLLECTIONS_PATH.
`requirements` pins each one exactly; `lock` is the committed
requirements.lock.json beside it, which `bazelisk run
@tbhb_rules_ansible//:lock` writes and ansible_collections_lock_test keeps in
step. Only the lock is read here.""",
    attrs = {
        "lock": attr.label(mandatory = True, doc = "The committed requirements.lock.json."),
        "requirements": attr.label(mandatory = True, doc = "The requirements.yml with the exact pins."),
    },
)

_ENV_ALIAS_BUILD = """\
alias(
    name = "env",
    actual = "@tbhb_ansible_tools//:env",
    visibility = ["//visibility:public"],
)
"""

def _env_alias_impl(rctx):
    rctx.file("BUILD.bazel", _ENV_ALIAS_BUILD)

_env_alias = repository_rule(implementation = _env_alias_impl)

def _lock_config_impl(rctx):
    rctx.file("BUILD.bazel", "")
    rctx.file("config.bzl", "REQUIREMENTS = {}\nLOCK = {}\n".format(
        repr(rctx.attr.requirements),
        repr(rctx.attr.lock),
    ))

_lock_config = repository_rule(
    implementation = _lock_config_impl,
    attrs = {
        "lock": attr.string(),
        "requirements": attr.string(),
    },
)

def _root_tag(mctx, tag_name):
    """The root module's one tag of `tag_name`, or None."""
    tags = []
    for mod in mctx.modules:
        found = getattr(mod.tags, tag_name)
        if found and not mod.is_root:
            fail("ansible.{}: only the root module may declare it, not {}".format(tag_name, mod.name))
        tags.extend(found)
    if len(tags) > 1:
        fail("ansible.{}: declare it at most once".format(tag_name))
    return tags[0] if tags else None

def _workspace_path(label, what):
    if label.repo_name != "":
        fail("ansible.collections: {} must be a file of the root module, not {}".format(what, label))
    return label.name if not label.package else label.package + "/" + label.name

def _collection_repo_name(collection):
    return "tbhb_ansible_collection_" + collection.replace(".", "_")

def _ansible_impl(mctx):
    python_env_repo(
        name = "tbhb_ansible_tools",
        lock = Label("//tools:uv.lock"),
        pyproject = Label("//tools:pyproject.toml"),
    )

    toolchain = _root_tag(mctx, "toolchain")
    if toolchain:
        python_env_repo(
            name = "tbhb_ansible",
            lock = toolchain.lock,
            pyproject = toolchain.pyproject,
            python_version = toolchain.python_version,
        )
    else:
        _env_alias(name = "tbhb_ansible")

    collections = _root_tag(mctx, "collections")
    repos = []
    if collections:
        # Before the first `bazelisk run @tbhb_rules_ansible//:lock` there is
        # no lock, and nothing is fetched: ansible_collections_lock_test
        # fails until it is written.
        # Renovate commits only files named requirements.lock.json after it
        # runs the lock command, so any other name would drop its output.
        if collections.lock.name != "requirements.lock.json":
            fail("ansible.collections: name the lock requirements.lock.json, not {}".format(collections.lock.name))
        lock_file = mctx.path(collections.lock)
        lock = json.decode(mctx.read(lock_file)).get("collections", {}) if lock_file.exists else {}
        for collection, pin in sorted(lock.items()):
            repo = _collection_repo_name(collection)
            collection_repo(
                name = repo,
                collection = collection,
                pinned = sorted(lock),
                sha256 = pin["sha256"],
                url = pin["url"],
                version = pin["version"],
            )
            repos.append(repo)
        _lock_config(
            name = "tbhb_ansible_lock",
            lock = _workspace_path(collections.lock, "lock"),
            requirements = _workspace_path(collections.requirements, "requirements"),
        )
    else:
        _lock_config(name = "tbhb_ansible_lock")
    collections_hub(name = "tbhb_ansible_collections", repos = repos)

    # Every repository is a function of committed files: the uv locks
    # (uv verifies every download against their hashes) and
    # requirements.lock.json (each tarball is fetched by sha256), so
    # nothing goes into MODULE.bazel.lock.
    return mctx.extension_metadata(reproducible = True)

ansible = module_extension(
    implementation = _ansible_impl,
    doc = """Builds @tbhb_ansible, the environment the checks default to (the
root module's `toolchain`, else this module's pins in tools/uv.lock), one
repository per pinned collection behind @tbhb_ansible_collections, and the
configuration of @tbhb_rules_ansible//:lock.""",
    tag_classes = {
        "collections": _collections,
        "toolchain": _toolchain,
    },
)
