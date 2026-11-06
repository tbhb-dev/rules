# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""What a collection's MANIFEST.json says against what the lock pins."""

# Internal: consumers use //:extensions.bzl.
visibility("//...")

def manifest_errors(collection, version, manifest, pinned):
    """Why a fetched collection does not match its pin, or [] when it does.

    Args:
        collection: The pinned `<namespace>.<name>`.
        version: The pinned version.
        manifest: The decoded MANIFEST.json.
        pinned: Every collection name the lock pins.

    Returns:
        A list of error messages.
    """
    info = manifest.get("collection_info", {})
    errors = []
    found = "{}.{}".format(info.get("namespace"), info.get("name"))
    if found != collection:
        errors.append("the tarball is {}, not {}".format(found, collection))
    if info.get("version") != version:
        errors.append("the tarball is version {}, not {}".format(info.get("version"), version))
    for dependency in sorted(info.get("dependencies") or {}):
        if dependency not in pinned:
            errors.append(
                "depends on {}, which requirements.yml does not pin: pin every transitive dependency there, then run `bazelisk run @tbhb_rules_ansible//:lock`".format(dependency),
            )
    return errors
