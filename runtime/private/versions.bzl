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
    "uv-aarch64-apple-darwin": ("https://github.com/astral-sh/uv/releases/download/0.13.8/uv-aarch64-apple-darwin.tar.gz", "6b71028a6b904f2ae3340ef52e595512de807d06c0a20eaef2f692581b246558"),
    "uv-aarch64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.8/uv-aarch64-unknown-linux-gnu.tar.gz", "74f2f5c6024d397481db228db8fc25eed420db192243f88438c118e7e013e585"),
    "uv-x86_64-pc-windows-msvc": ("https://github.com/astral-sh/uv/releases/download/0.13.8/uv-x86_64-pc-windows-msvc.zip", "529e78a9cec6cd7e3e014f7ecd8bda0c113969d4ed0f2efeedb85c30943325b8"),
    "uv-x86_64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.8/uv-x86_64-unknown-linux-gnu.tar.gz", "5acfd9177cfecf0bf87578f059728215ccc884388988f55f7a65041b57387d91"),
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
