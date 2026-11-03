# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The pinned uv, which installs the interpreter and the locked packages."""

# Internal.
visibility("//...")

UV_VERSION = "0.13.6"

# Release assets by (os, arch) as Bazel's repository_ctx reports them, with
# the sha256 GitHub lists for each asset.
UV_ASSETS = {
    ("linux", "aarch64"): ("uv-aarch64-unknown-linux-gnu", "229e194255c7958d86d56e8790d969a6f74736592133f0dfd0076f754c642c1d"),
    ("linux", "amd64"): ("uv-x86_64-unknown-linux-gnu", "f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645"),
    ("linux", "x86_64"): ("uv-x86_64-unknown-linux-gnu", "f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645"),
    ("mac os x", "aarch64"): ("uv-aarch64-apple-darwin", "60fbd5c8a1ed681845eea28d9d622fcde03c51e91a43465b64a1e17db1ed3472"),
}
