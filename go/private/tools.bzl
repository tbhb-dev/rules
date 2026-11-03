# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`tools`: the prebuilt tool binaries this module runs, one archive per platform.

Each archive is a literal `http_archive` call with its URL and sha256 spelled
out, so Renovate's bazel manager can bump the version and the hash.
`//private:golangci_lint_bin` and `//private:go_arch_lint_bin` select the
archive for the platform.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# Internal: MODULE.bazel uses it.
visibility(["//"])

_BUILD = 'exports_files(["{}"], visibility = ["//visibility:public"])'

def _tools_impl(module_ctx):
    golangci_lint = _BUILD.format("golangci-lint")
    http_archive(
        name = "golangci_lint_darwin_arm64",
        build_file_content = golangci_lint,
        sha256 = "d1e409481a8ca846c4bc97e781eb5cb1bd5c23353a0b3977a1cbda1b1b6447d5",
        strip_prefix = "golangci-lint-2.15.0-darwin-arm64",
        urls = ["https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-darwin-arm64.tar.gz"],
    )
    http_archive(
        name = "golangci_lint_linux_amd64",
        build_file_content = golangci_lint,
        sha256 = "9b7fe6a6bf6334b98decf8d86b11415ea7889afdabdd1959fdce23af2a9ebcea",
        strip_prefix = "golangci-lint-2.15.0-linux-amd64",
        urls = ["https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-linux-amd64.tar.gz"],
    )
    http_archive(
        name = "golangci_lint_linux_arm64",
        build_file_content = golangci_lint,
        sha256 = "b4d8f17068b35ee6060cc2f69a16fb48740d706fbba81661c318649c114a6998",
        strip_prefix = "golangci-lint-2.15.0-linux-arm64",
        urls = ["https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-linux-arm64.tar.gz"],
    )

    go_arch_lint = _BUILD.format("go-arch-lint")
    http_archive(
        name = "go_arch_lint_darwin_arm64",
        build_file_content = go_arch_lint,
        sha256 = "e2e9e80594afe21c2e2aedddcfce8df77eca19b055cfce0a1be11e85d06c9e49",
        urls = ["https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_darwin_arm64.tar.gz"],
    )
    http_archive(
        name = "go_arch_lint_linux_amd64",
        build_file_content = go_arch_lint,
        sha256 = "26730d19b6acd20f3e922f71f5a7ec1c4e873894666fa9ad7bf03496ac17b06e",
        urls = ["https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_linux_amd64.tar.gz"],
    )
    http_archive(
        name = "go_arch_lint_linux_arm64",
        build_file_content = go_arch_lint,
        sha256 = "57a7b08c375db614a3504df421dbff60209a5f5e444298a26b316889666b5484",
        urls = ["https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_linux_arm64.tar.gz"],
    )
    return module_ctx.extension_metadata(reproducible = True)

tools = module_extension(
    implementation = _tools_impl,
    doc = "The prebuilt tools of this module: golangci-lint and go-arch-lint, per platform.",
)
