# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`tools`: the prebuilt tool binaries this module runs.

The same shape as @tbhb_rules//pins: every binary is a literal
`http_archive` call, one per tool and platform, so Renovate's bazel manager
can move a version by rewriting the URL and recomputing its sha256, and each
tool has a hub, `tbhb_rules_<tool>`, whose `//:<tool>` target picks the
binary for the target platform. A consumer replaces one with `override_repo`:

    tools = use_extension("@tbhb_rules_go//private:tools.bzl", "tools")
    override_repo(tools, tbhb_rules_golangci_lint = "my_golangci_lint")
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@tbhb_rules//pins:hub.bzl", "EXPORT", "PLATFORMS", "tool_hub")

def _tools_impl(module_ctx):
    http_archive(
        name = "tbhb_rules_golangci_lint_macos_arm64",
        build_file_content = EXPORT.format("golangci-lint"),
        sha256 = "d1e409481a8ca846c4bc97e781eb5cb1bd5c23353a0b3977a1cbda1b1b6447d5",
        strip_prefix = "golangci-lint-2.15.0-darwin-arm64",
        url = "https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-darwin-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_golangci_lint_linux_x86_64",
        build_file_content = EXPORT.format("golangci-lint"),
        sha256 = "9b7fe6a6bf6334b98decf8d86b11415ea7889afdabdd1959fdce23af2a9ebcea",
        strip_prefix = "golangci-lint-2.15.0-linux-amd64",
        url = "https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-linux-amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_golangci_lint_linux_arm64",
        build_file_content = EXPORT.format("golangci-lint"),
        sha256 = "b4d8f17068b35ee6060cc2f69a16fb48740d706fbba81661c318649c114a6998",
        strip_prefix = "golangci-lint-2.15.0-linux-arm64",
        url = "https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-linux-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_golangci_lint_windows_x86_64",
        build_file_content = EXPORT.format("golangci-lint.exe"),
        sha256 = "cd7ea6063c95de245e17e5246e42bdc14bb221792c429dbd239ab3a6ade6ca6a",
        strip_prefix = "golangci-lint-2.15.0-windows-amd64",
        url = "https://github.com/golangci/golangci-lint/releases/download/v2.15.0/golangci-lint-2.15.0-windows-amd64.zip",
    )

    http_archive(
        name = "tbhb_rules_go_arch_lint_macos_arm64",
        build_file_content = EXPORT.format("go-arch-lint"),
        sha256 = "e2e9e80594afe21c2e2aedddcfce8df77eca19b055cfce0a1be11e85d06c9e49",
        url = "https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_darwin_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_go_arch_lint_linux_x86_64",
        build_file_content = EXPORT.format("go-arch-lint"),
        sha256 = "26730d19b6acd20f3e922f71f5a7ec1c4e873894666fa9ad7bf03496ac17b06e",
        url = "https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_linux_amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_go_arch_lint_linux_arm64",
        build_file_content = EXPORT.format("go-arch-lint"),
        sha256 = "57a7b08c375db614a3504df421dbff60209a5f5e444298a26b316889666b5484",
        url = "https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_go_arch_lint_windows_x86_64",
        build_file_content = EXPORT.format("go-arch-lint.exe"),
        sha256 = "15f1ad56d89edc5290e0a15f398975d92bc71a397ac5093676964d6ebc8af6e8",
        url = "https://github.com/fe3dback/go-arch-lint/releases/download/v1.19.1/go-arch-lint_1.19.1_windows_amd64.zip",
    )

    tool_hub(
        name = "tbhb_rules_golangci_lint",
        tool = "golangci-lint",
        binaries = {
            "linux_arm64": "@tbhb_rules_golangci_lint_linux_arm64//:golangci-lint",
            "linux_x86_64": "@tbhb_rules_golangci_lint_linux_x86_64//:golangci-lint",
            "macos_arm64": "@tbhb_rules_golangci_lint_macos_arm64//:golangci-lint",
            "windows_x86_64": "@tbhb_rules_golangci_lint_windows_x86_64//:golangci-lint.exe",
        },
    )

    tool_hub(
        name = "tbhb_rules_go_arch_lint",
        tool = "go-arch-lint",
        binaries = {
            "linux_arm64": "@tbhb_rules_go_arch_lint_linux_arm64//:go-arch-lint",
            "linux_x86_64": "@tbhb_rules_go_arch_lint_linux_x86_64//:go-arch-lint",
            "macos_arm64": "@tbhb_rules_go_arch_lint_macos_arm64//:go-arch-lint",
            "windows_x86_64": "@tbhb_rules_go_arch_lint_windows_x86_64//:go-arch-lint.exe",
        },
    )

    # gomutants has no release for every platform, so rules_go builds it
    # from the `tool` directive in go.mod, which Renovate's gomod manager
    # bumps; the hub gives it the same interface as the prebuilt tools.
    gomutants = str(Label("@com_github_gomutants_gomutants//:gomutants"))
    tool_hub(
        name = "tbhb_rules_gomutants",
        tool = "gomutants",
        binaries = {platform: gomutants for platform in PLATFORMS},
    )

    return module_ctx.extension_metadata(reproducible = True)

tools = module_extension(
    implementation = _tools_impl,
    doc = "The tools of this module: golangci-lint and go-arch-lint (prebuilt) and gomutants (built from go.mod).",
)
