# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The `runtime` extension: tbhb_rules' own pinned Python tools."""

load("//runtime/private:repo.bzl", "python_env_repo")

def _runtime_impl(mctx):
    python_env_repo(
        name = "tbhb_rules_python_runtime",
        lock = Label("//runtime/tools:uv.lock"),
        pyproject = Label("//runtime/tools:pyproject.toml"),
    )

    # A function of the committed lock (uv verifies every download against
    # its hashes), so nothing about it goes into MODULE.bazel.lock.
    return mctx.extension_metadata(reproducible = True)

runtime = module_extension(
    implementation = _runtime_impl,
    doc = "Builds @tbhb_rules_python_runtime from runtime/tools/uv.lock.",
)
