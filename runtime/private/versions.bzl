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
    "uv-aarch64-apple-darwin": ("https://github.com/astral-sh/uv/releases/download/0.13.9/uv-aarch64-apple-darwin.tar.gz", "5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca"),
    "uv-aarch64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.9/uv-aarch64-unknown-linux-gnu.tar.gz", "0797542018e541a9288855df555c8077eed06f7a47d206362030480e8ecc9f3d"),
    "uv-x86_64-pc-windows-msvc": ("https://github.com/astral-sh/uv/releases/download/0.13.9/uv-x86_64-pc-windows-msvc.zip", "edd61f7f5728a56cc62455386661860bdfc7bab65872f39b0c25bdcc1d8e1beb"),
    "uv-x86_64-unknown-linux-gnu": ("https://github.com/astral-sh/uv/releases/download/0.13.9/uv-x86_64-unknown-linux-gnu.tar.gz", "a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5"),
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
