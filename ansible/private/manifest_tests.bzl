# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Unit tests of manifest_errors."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":manifest.bzl", "manifest_errors")

def _manifest(namespace = "ansible", name = "posix", version = "2.1.0", dependencies = None):
    info = {"name": name, "namespace": namespace, "version": version}
    if dependencies != None:
        info["dependencies"] = dependencies
    return {"collection_info": info}

def _matching_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], manifest_errors("ansible.posix", "2.1.0", _manifest(), ["ansible.posix"]))
    asserts.equals(env, [], manifest_errors("ansible.posix", "2.1.0", _manifest(dependencies = {}), ["ansible.posix"]))
    asserts.equals(env, [], manifest_errors(
        "ansible.posix",
        "2.1.0",
        _manifest(dependencies = {"ansible.utils": ">=1.0.0"}),
        ["ansible.posix", "ansible.utils"],
    ))
    return unittest.end(env)

_matching_test = unittest.make(_matching_impl)

def _mismatch_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["the tarball is community.general, not ansible.posix"],
        manifest_errors("ansible.posix", "2.1.0", _manifest(namespace = "community", name = "general"), ["ansible.posix"]),
    )
    asserts.equals(
        env,
        ["the tarball is version 2.0.0, not 2.1.0"],
        manifest_errors("ansible.posix", "2.1.0", _manifest(version = "2.0.0"), ["ansible.posix"]),
    )
    return unittest.end(env)

_mismatch_test = unittest.make(_mismatch_impl)

def _missing_dependency_impl(ctx):
    env = unittest.begin(ctx)
    errors = manifest_errors(
        "ansible.posix",
        "2.1.0",
        _manifest(dependencies = {"ansible.netcommon": ">=2.0.0", "ansible.utils": "*"}),
        ["ansible.posix", "ansible.utils"],
    )
    asserts.equals(env, 1, len(errors))
    asserts.true(env, errors[0].startswith("depends on ansible.netcommon, which requirements.yml does not pin"), errors[0])
    asserts.true(env, "bazelisk run @tbhb_rules_ansible//:lock" in errors[0], errors[0])
    return unittest.end(env)

_missing_dependency_test = unittest.make(_missing_dependency_impl)

def manifest_test_suite(name):
    unittest.suite(
        name,
        _matching_test,
        _mismatch_test,
        _missing_dependency_test,
    )
