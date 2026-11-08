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
    "uv-aarch64-apple-darwin": ("https://github.com/astral-sh/uv/releases/download/0.13.7/uv-aarch64-apple-darwin.tar.gz", "81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731"),
    "uv-aarch64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.7/uv-aarch64-unknown-linux-gnu.tar.gz", "71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc"),
    "uv-x86_64-pc-windows-msvc": ("https://github.com/astral-sh/uv/releases/download/0.13.7/uv-x86_64-pc-windows-msvc.zip", "0cdc5b38fe5a8168ed6a25814f5ba43c21d313dd3187314fccb37b7cec46e021"),
    "uv-x86_64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.7/uv-x86_64-unknown-linux-gnu.tar.gz", "c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83"),
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
