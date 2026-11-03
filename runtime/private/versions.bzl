# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The pinned uv, which installs the interpreter and the locked packages.

uv's own download metadata pins the python-build-standalone build for each
Python version, with its sha256, so the interpreter moves with this pin.

Each asset line carries the release URL, which holds the version, and the
asset's sha256, the shape a Renovate regex manager with the
github-release-attachments datasource reads and rewrites.

uv is the one pinned tool that doesn't go through a //pins hub: the runtime
repository rule runs it while fetching, and a hub's targets exist only at
build time.
"""

# Internal: load //runtime:defs.bzl.
visibility("//runtime/...")

# Release assets of astral-sh/uv: asset name -> (url, sha256), one literal
# per line for Renovate's regex manager.
UV_ASSETS = {
    "uv-aarch64-apple-darwin": ("https://github.com/astral-sh/uv/releases/download/0.13.6/uv-aarch64-apple-darwin.tar.gz", "60fbd5c8a1ed681845eea28d9d622fcde03c51e91a43465b64a1e17db1ed3472"),
    "uv-aarch64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.6/uv-aarch64-unknown-linux-gnu.tar.gz", "229e194255c7958d86d56e8790d969a6f74736592133f0dfd0076f754c642c1d"),
    "uv-x86_64-pc-windows-msvc": ("https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-pc-windows-msvc.zip", "a2a8820d5eea32f08ef467ef3b7f66883a9b076d5737a2fc2fbb5f458d1bb50f"),
    "uv-x86_64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-unknown-linux-gnu.tar.gz", "f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645"),
}

# (os, arch) as repository_ctx reports them -> asset name. Windows reports
# its release in the name ("windows 11"), so _uv matches it as "windows".
UV_PLATFORMS = {
    ("linux", "aarch64"): "uv-aarch64-unknown-linux-gnu",
    ("linux", "amd64"): "uv-x86_64-unknown-linux-gnu",
    ("linux", "x86_64"): "uv-x86_64-unknown-linux-gnu",
    ("mac os x", "aarch64"): "uv-aarch64-apple-darwin",
    ("windows", "amd64"): "uv-x86_64-pc-windows-msvc",
}
