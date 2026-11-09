# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Unit tests of python_mismatch_hint."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":python_mismatch.bzl", "python_mismatch_hint")

_STDERR = "error: The requested interpreter resolved to Python 3.14.10, which is incompatible with the project's Python requirement: `==3.15.*` (from `project.requires-python`)"

_PYPROJECT = """\
[build-system]
requires = ["hatchling"]

[project]
name = "example"
requires-python = "==3.15.*"  # pinned

[tool.other]
requires-python = ">=3.0"
"""

def _found_impl(ctx):
    env = unittest.begin(ctx)
    hint = python_mismatch_hint(_STDERR, "3.14", _PYPROJECT)
    asserts.true(env, "Python 3.14" in hint, hint)
    asserts.true(env, "requires-python is ==3.15.*" in hint, hint)
    asserts.true(env, "Bump .python-version" in hint, hint)
    asserts.true(env, "python_version on the" in hint, hint)
    return unittest.end(env)

_found_test = unittest.make(_found_impl)

def _missing_impl(ctx):
    env = unittest.begin(ctx)
    for pyproject in ["", "[project]\nname = \"x\"\n", "[tool.x]\nrequires-python = \">=3\"\n", "[project]\nrequires-python-extra = 1\n"]:
        hint = python_mismatch_hint(_STDERR, "3.14", pyproject)
        asserts.true(env, "Python 3.14" in hint, hint)
        asserts.true(env, "has no requires-python under [project]" in hint, hint)
    return unittest.end(env)

_missing_test = unittest.make(_missing_impl)

def _other_failure_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", python_mismatch_hint("error: network unreachable", "3.14", _PYPROJECT))
    return unittest.end(env)

_other_failure_test = unittest.make(_other_failure_impl)

def python_mismatch_test_suite(name):
    unittest.suite(
        name,
        _found_test,
        _missing_test,
        _other_failure_test,
    )
