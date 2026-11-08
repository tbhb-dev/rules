# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The pinned tool binaries behind tbhb_rules' checks and formatters.

Every binary is a literal `http_archive` or `http_file` call, one per tool
and platform, so Renovate's bazel manager can move a version by rewriting
the URL and recomputing its sha256. Each tool also gets a hub repository,
`tbhb_rules_<tool>`, whose `//:<tool>` target picks the binary for the
target platform. Rules refer only to those hub labels.

A consumer replaces one tool with Bazel's `override_repo`:

    tools = use_extension("@tbhb_rules//pins:extensions.bzl", "tools")
    override_repo(tools, tbhb_rules_gitleaks = "my_gitleaks")

where `my_gitleaks` is any repository with a `//:gitleaks` target.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load(":hub.bzl", _EXPORT = "EXPORT", _EXPORT_TREE = "EXPORT_TREE", _tool_hub = "tool_hub")

def _tools_impl(mctx):
    # dugite-native is not relocatable on its own (pins/git_wrapper.sh): the
    # macOS and Linux archives get a wrapper beside bin/git that sets the
    # environment dugite sets, and the git hub exports the wrapper with the
    # whole tree, which the wrapper's real git needs beside it.
    git_patch_cmds = [
        "cat > bin/git-wrapper <<'TBHB_RULES_EOF'\n{}TBHB_RULES_EOF".format(mctx.read(Label("//pins:git_wrapper.sh"))),
        "chmod +x bin/git-wrapper",
    ]

    http_archive(
        name = "tbhb_rules_actionlint_macos_arm64",
        build_file_content = _EXPORT.format("actionlint"),
        sha256 = "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
        url = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_actionlint_linux_x86_64",
        build_file_content = _EXPORT.format("actionlint"),
        sha256 = "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
        url = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_actionlint_linux_arm64",
        build_file_content = _EXPORT.format("actionlint"),
        sha256 = "325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
        url = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_bats_source",
        build_file_content = _EXPORT.format("bin/bats"),
        sha256 = "bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177",
        strip_prefix = "bats-core-1.14.0",
        url = "https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_cog_macos_arm64",
        build_file_content = _EXPORT.format("cog"),
        sha256 = "429303b6d68c6461aa221ab4de82b26d0bbcdee7127947ea9c7c411ab9bc574c",
        strip_prefix = "aarch64-apple-darwin",
        url = "https://github.com/cocogitto/cocogitto/releases/download/7.0.0/cocogitto-7.0.0-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_cog_linux_x86_64",
        build_file_content = _EXPORT.format("cog"),
        sha256 = "e03938ff2c4c86d71c00c0f3284dbbe95c5ca76fe34a51f33e945c23010d59bb",
        strip_prefix = "x86_64-unknown-linux-musl",
        url = "https://github.com/cocogitto/cocogitto/releases/download/7.0.0/cocogitto-7.0.0-x86_64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_cog_linux_arm64",
        build_file_content = _EXPORT.format("cog"),
        sha256 = "379949f50c4f8245ef9532913e83f351c048b55e40ebd52ed8a850642c07a753",
        strip_prefix = "aarch64-unknown-linux-gnu",
        url = "https://github.com/cocogitto/cocogitto/releases/download/7.0.0/cocogitto-7.0.0-aarch64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_editorconfig_checker_macos_arm64",
        build_file_content = _EXPORT.format("editorconfig-checker"),
        sha256 = "ff59f57717d95fc62b8e372c8051dbbb766f7d660942409a85d027b0feb2422c",
        url = "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v4.0.2/editorconfig-checker-darwin-all.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_editorconfig_checker_linux_x86_64",
        build_file_content = _EXPORT.format("editorconfig-checker"),
        sha256 = "44efaef3ed14c6ab52eb87481d78e5e5c204796dccf26e2f4598a61ba17f8003",
        url = "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v4.0.2/editorconfig-checker-linux-amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_editorconfig_checker_linux_arm64",
        build_file_content = _EXPORT.format("editorconfig-checker"),
        sha256 = "abad76da8c9950fdc2a314bcd66969172aa823e9c595fa7e3a389a91e34d025e",
        url = "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v4.0.2/editorconfig-checker-linux-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_git_macos_arm64",
        build_file_content = _EXPORT_TREE.format("bin/git-wrapper"),
        patch_cmds = git_patch_cmds,
        sha256 = "1110de343de11cc6f469b782b60f36217b9199b5e06875dd65baa26dd60563c7",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.0-2/dugite-native-v2.56.0-a44aeca-macOS-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_git_linux_x86_64",
        build_file_content = _EXPORT_TREE.format("bin/git-wrapper"),
        patch_cmds = git_patch_cmds,
        sha256 = "1efd8ce0516b670b6b6d0f49ecaf395ceb8cf7fff3f5857259763d97a1238df9",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.0-2/dugite-native-v2.56.0-a44aeca-ubuntu-x64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_git_linux_arm64",
        build_file_content = _EXPORT_TREE.format("bin/git-wrapper"),
        patch_cmds = git_patch_cmds,
        sha256 = "d5ce120515bf3013a014e6a918aa87ec0f7a6f5f9687c48d50127e637cb9b6c2",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.0-2/dugite-native-v2.56.0-a44aeca-ubuntu-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_gitleaks_macos_arm64",
        build_file_content = _EXPORT.format("gitleaks"),
        sha256 = "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
        url = "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_gitleaks_linux_x86_64",
        build_file_content = _EXPORT.format("gitleaks"),
        sha256 = "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb",
        url = "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_gitleaks_linux_arm64",
        build_file_content = _EXPORT.format("gitleaks"),
        sha256 = "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080",
        url = "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_rumdl_macos_arm64",
        build_file_content = _EXPORT.format("rumdl"),
        sha256 = "a1eefb1cd2e0cafa42f0ca98d3f8713d7e73f9eba77fc8ef0ed6836875197935",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.2/rumdl-v0.3.2-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_rumdl_linux_x86_64",
        build_file_content = _EXPORT.format("rumdl"),
        sha256 = "f527d1374765d826c1627ceab3d1f46e548268731a495b5b12a3af529b3d79e8",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.2/rumdl-v0.3.2-x86_64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_rumdl_linux_arm64",
        build_file_content = _EXPORT.format("rumdl"),
        sha256 = "bdfca7a602f893fbe5d73d5e38f73b31f45a21d3bcf385b6ea819997d0449ec3",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.2/rumdl-v0.3.2-aarch64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_ryl_macos_arm64",
        build_file_content = _EXPORT.format("ryl"),
        sha256 = "a1120c6b6974bd63198eb2fd06cf8f220620d0aa3f4348634fbe7d04dd74c602",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.28.0/ryl-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_ryl_linux_x86_64",
        build_file_content = _EXPORT.format("ryl"),
        sha256 = "6e0ae1db5dc9b3b3f7c389eca845b3665eee72e3a400eea32155ccc36b27469d",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.28.0/ryl-x86_64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_ryl_linux_arm64",
        build_file_content = _EXPORT.format("ryl"),
        sha256 = "8a4d3f7ea93bd5cf96d1a1d49732869c26e7ac126e38811d6650b53d1656ccba",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.28.0/ryl-aarch64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_shellcheck_macos_arm64",
        build_file_content = _EXPORT.format("shellcheck"),
        sha256 = "56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79",
        strip_prefix = "shellcheck-v0.11.0",
        url = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz",
    )

    http_archive(
        name = "tbhb_rules_shellcheck_linux_x86_64",
        build_file_content = _EXPORT.format("shellcheck"),
        sha256 = "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
        strip_prefix = "shellcheck-v0.11.0",
        url = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz",
    )

    http_archive(
        name = "tbhb_rules_shellcheck_linux_arm64",
        build_file_content = _EXPORT.format("shellcheck"),
        sha256 = "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588",
        strip_prefix = "shellcheck-v0.11.0",
        url = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.aarch64.tar.xz",
    )

    http_file(
        name = "tbhb_rules_shfmt_macos_arm64",
        downloaded_file_path = "shfmt",
        executable = True,
        sha256 = "b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5",
        url = "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_darwin_arm64",
    )

    http_file(
        name = "tbhb_rules_shfmt_linux_x86_64",
        downloaded_file_path = "shfmt",
        executable = True,
        sha256 = "76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf",
        url = "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_linux_amd64",
    )

    http_file(
        name = "tbhb_rules_shfmt_linux_arm64",
        downloaded_file_path = "shfmt",
        executable = True,
        sha256 = "5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489",
        url = "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_linux_arm64",
    )

    http_archive(
        name = "tbhb_rules_tombi_macos_arm64",
        build_file_content = _EXPORT.format("tombi"),
        sha256 = "7d07cad962ad3de96113b92f40fbb59617a9214f263027c14a66fd08b61289ec",
        strip_prefix = "tombi-cli-1.9.8-aarch64-apple-darwin",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.9.8/tombi-cli-1.9.8-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_tombi_linux_x86_64",
        build_file_content = _EXPORT.format("tombi"),
        sha256 = "cf51b0f134e5b488212bb062538e0381a163a4f7db2330c58e3cf613637b3118",
        strip_prefix = "tombi-cli-1.9.8-x86_64-unknown-linux-musl",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.9.8/tombi-cli-1.9.8-x86_64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_tombi_linux_arm64",
        build_file_content = _EXPORT.format("tombi"),
        sha256 = "696d6b934fd0c4fa002ae905dc72a551d54677d9caa7b272adee3ea27e056307",
        strip_prefix = "tombi-cli-1.9.8-aarch64-unknown-linux-musl",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.9.8/tombi-cli-1.9.8-aarch64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_vale_macos_arm64",
        build_file_content = _EXPORT.format("vale"),
        sha256 = "a6c3370f53bad93086c6b85f3163676e44e08049d69743afdcc13f3aab5b7482",
        url = "https://github.com/vale-cli/vale/releases/download/v3.26.0/vale_3.26.0_macOS_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_vale_linux_x86_64",
        build_file_content = _EXPORT.format("vale"),
        sha256 = "22aa69a556558e4a9dfc63c17030777383d8d3c48dcdfad655fa98e839d666ed",
        url = "https://github.com/vale-cli/vale/releases/download/v3.26.0/vale_3.26.0_Linux_64-bit.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_vale_linux_arm64",
        build_file_content = _EXPORT.format("vale"),
        sha256 = "3154179f4611140c9af54a8b3bc6a90bc02b73fe6c1f635369604dde0490406d",
        url = "https://github.com/vale-cli/vale/releases/download/v3.26.0/vale_3.26.0_Linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_zizmor_macos_arm64",
        build_file_content = _EXPORT.format("zizmor"),
        sha256 = "6efed18c4539a663fd3c851a2be9533fd8456c4e646d9416206da059154a0d3c",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_zizmor_linux_x86_64",
        build_file_content = _EXPORT.format("zizmor"),
        sha256 = "bb110cc765eca9cd7efb2e284a956be5974c60027b0970f16397d86208a9957b",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-x86_64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_zizmor_linux_arm64",
        build_file_content = _EXPORT.format("zizmor"),
        sha256 = "cb152b207f815116d7fa1c1ee4614f61578803351395052908095e79adfd9fd0",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-aarch64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_actionlint_windows_x86_64",
        build_file_content = _EXPORT.format("actionlint.exe"),
        sha256 = "6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9",
        url = "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_windows_amd64.zip",
    )

    http_archive(
        name = "tbhb_rules_cog_windows_x86_64",
        build_file_content = _EXPORT.format("cog.exe"),
        sha256 = "074f68f05d270da5c0d69d3e234ec362bec4c6e3189c21d1c948d038603655d7",
        strip_prefix = "x86_64-pc-windows-msvc",
        url = "https://github.com/cocogitto/cocogitto/releases/download/7.0.0/cocogitto-7.0.0-x86_64-pc-windows-msvc.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_editorconfig_checker_windows_x86_64",
        build_file_content = _EXPORT.format("editorconfig-checker.exe"),
        sha256 = "857f8f74dfc259d73dac93573e37cf3ce01150787d7b139bf839549cc6b5beb9",
        url = "https://github.com/editorconfig-checker/editorconfig-checker/releases/download/v4.0.2/editorconfig-checker-windows-amd64.zip",
    )

    http_archive(
        name = "tbhb_rules_git_windows_x86_64",
        build_file_content = _EXPORT_TREE.format("cmd/git.exe"),
        sha256 = "f1e17876337d7be143e5d51976da36643d65528125cfbc14d57f171de0fd5f14",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.0-2/dugite-native-v2.56.0-a44aeca-windows-x64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_gitleaks_windows_x86_64",
        build_file_content = _EXPORT.format("gitleaks.exe"),
        sha256 = "d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e",
        url = "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip",
    )

    http_archive(
        name = "tbhb_rules_rumdl_windows_x86_64",
        build_file_content = _EXPORT.format("rumdl.exe"),
        sha256 = "87a632668c55969a7d916f214a28a7d365f6a68ec626b547bd1243e035b9c7ff",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.2/rumdl-v0.3.2-x86_64-pc-windows-msvc.zip",
    )

    http_archive(
        name = "tbhb_rules_ryl_windows_x86_64",
        build_file_content = _EXPORT.format("ryl.exe"),
        sha256 = "62c94c30d7eee67126f2b465c4a3d920a89ec18e9f66359b88b301b5a1cefa4d",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.28.0/ryl-x86_64-pc-windows-msvc.zip",
    )

    http_archive(
        name = "tbhb_rules_shellcheck_windows_x86_64",
        build_file_content = _EXPORT.format("shellcheck.exe"),
        sha256 = "8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e",
        url = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.zip",
    )

    http_archive(
        name = "tbhb_rules_tombi_windows_x86_64",
        build_file_content = _EXPORT.format("tombi.exe"),
        sha256 = "df4be8cac00b00c5b0d421723fc25c959539a355a1407ac6ec97c9d30669c622",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.9.8/tombi-cli-1.9.8-x86_64-pc-windows-msvc.zip",
    )

    http_archive(
        name = "tbhb_rules_vale_windows_x86_64",
        build_file_content = _EXPORT.format("vale.exe"),
        sha256 = "c42f4b413aa29b6b36fa4e3ac0c18322588a54ac860db4c84b8255997f7d1ec2",
        url = "https://github.com/vale-cli/vale/releases/download/v3.26.0/vale_3.26.0_Windows_64-bit.zip",
    )

    http_archive(
        name = "tbhb_rules_zizmor_windows_x86_64",
        build_file_content = _EXPORT.format("zizmor.exe"),
        sha256 = "d284a16e09d9df4ce2c000357e7b59bd531be093bea5718a1ce225b449b59d49",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-x86_64-pc-windows-msvc.zip",
    )

    http_file(
        name = "tbhb_rules_shfmt_windows_x86_64",
        downloaded_file_path = "shfmt.exe",
        executable = True,
        sha256 = "13629ce28442ca80b6b5a819f7574ab39e1c28c6e26734ca816c9714e04851df",
        url = "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_windows_amd64.exe",
    )

    _tool_hub(
        name = "tbhb_rules_actionlint",
        tool = "actionlint",
        binaries = {
            "linux_arm64": "@tbhb_rules_actionlint_linux_arm64//:actionlint",
            "linux_x86_64": "@tbhb_rules_actionlint_linux_x86_64//:actionlint",
            "macos_arm64": "@tbhb_rules_actionlint_macos_arm64//:actionlint",
            "windows_x86_64": "@tbhb_rules_actionlint_windows_x86_64//:actionlint.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_bats",
        tool = "bats",
        binaries = {
            "linux_arm64": "@tbhb_rules_bats_source//:bin/bats",
            "linux_x86_64": "@tbhb_rules_bats_source//:bin/bats",
            "macos_arm64": "@tbhb_rules_bats_source//:bin/bats",
            "windows_x86_64": "@tbhb_rules_bats_source//:bin/bats",
        },
    )

    # buildifier comes from buildifier_prebuilt, whose extension fetches the
    # binaries (MODULE.bazel names its repositories).
    _tool_hub(
        name = "tbhb_rules_buildifier",
        tool = "buildifier",
        binaries = {
            "linux_arm64": "@buildifier_linux_arm64//file:buildifier",
            "linux_x86_64": "@buildifier_linux_amd64//file:buildifier",
            "macos_arm64": "@buildifier_darwin_arm64//file:buildifier",
            "windows_x86_64": "@buildifier_windows_amd64//file:buildifier.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_cog",
        tool = "cog",
        binaries = {
            "linux_arm64": "@tbhb_rules_cog_linux_arm64//:cog",
            "linux_x86_64": "@tbhb_rules_cog_linux_x86_64//:cog",
            "macos_arm64": "@tbhb_rules_cog_macos_arm64//:cog",
            "windows_x86_64": "@tbhb_rules_cog_windows_x86_64//:cog.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_editorconfig_checker",
        tool = "editorconfig-checker",
        binaries = {
            "linux_arm64": "@tbhb_rules_editorconfig_checker_linux_arm64//:editorconfig-checker",
            "linux_x86_64": "@tbhb_rules_editorconfig_checker_linux_x86_64//:editorconfig-checker",
            "macos_arm64": "@tbhb_rules_editorconfig_checker_macos_arm64//:editorconfig-checker",
            "windows_x86_64": "@tbhb_rules_editorconfig_checker_windows_x86_64//:editorconfig-checker.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_git",
        tool = "git",
        binaries = {
            "linux_arm64": "@tbhb_rules_git_linux_arm64//:bin/git-wrapper",
            "linux_x86_64": "@tbhb_rules_git_linux_x86_64//:bin/git-wrapper",
            "macos_arm64": "@tbhb_rules_git_macos_arm64//:bin/git-wrapper",
            "windows_x86_64": "@tbhb_rules_git_windows_x86_64//:cmd/git.exe",
        },
        data = {
            "linux_arm64": "@tbhb_rules_git_linux_arm64//:tree",
            "linux_x86_64": "@tbhb_rules_git_linux_x86_64//:tree",
            "macos_arm64": "@tbhb_rules_git_macos_arm64//:tree",
            "windows_x86_64": "@tbhb_rules_git_windows_x86_64//:tree",
        },
    )

    _tool_hub(
        name = "tbhb_rules_gitleaks",
        tool = "gitleaks",
        binaries = {
            "linux_arm64": "@tbhb_rules_gitleaks_linux_arm64//:gitleaks",
            "linux_x86_64": "@tbhb_rules_gitleaks_linux_x86_64//:gitleaks",
            "macos_arm64": "@tbhb_rules_gitleaks_macos_arm64//:gitleaks",
            "windows_x86_64": "@tbhb_rules_gitleaks_windows_x86_64//:gitleaks.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_rumdl",
        tool = "rumdl",
        binaries = {
            "linux_arm64": "@tbhb_rules_rumdl_linux_arm64//:rumdl",
            "linux_x86_64": "@tbhb_rules_rumdl_linux_x86_64//:rumdl",
            "macos_arm64": "@tbhb_rules_rumdl_macos_arm64//:rumdl",
            "windows_x86_64": "@tbhb_rules_rumdl_windows_x86_64//:rumdl.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_ryl",
        tool = "ryl",
        binaries = {
            "linux_arm64": "@tbhb_rules_ryl_linux_arm64//:ryl",
            "linux_x86_64": "@tbhb_rules_ryl_linux_x86_64//:ryl",
            "macos_arm64": "@tbhb_rules_ryl_macos_arm64//:ryl",
            "windows_x86_64": "@tbhb_rules_ryl_windows_x86_64//:ryl.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_shellcheck",
        tool = "shellcheck",
        binaries = {
            "linux_arm64": "@tbhb_rules_shellcheck_linux_arm64//:shellcheck",
            "linux_x86_64": "@tbhb_rules_shellcheck_linux_x86_64//:shellcheck",
            "macos_arm64": "@tbhb_rules_shellcheck_macos_arm64//:shellcheck",
            "windows_x86_64": "@tbhb_rules_shellcheck_windows_x86_64//:shellcheck.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_shfmt",
        tool = "shfmt",
        binaries = {
            "linux_arm64": "@tbhb_rules_shfmt_linux_arm64//file:shfmt",
            "linux_x86_64": "@tbhb_rules_shfmt_linux_x86_64//file:shfmt",
            "macos_arm64": "@tbhb_rules_shfmt_macos_arm64//file:shfmt",
            "windows_x86_64": "@tbhb_rules_shfmt_windows_x86_64//file:shfmt.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_tombi",
        tool = "tombi",
        binaries = {
            "linux_arm64": "@tbhb_rules_tombi_linux_arm64//:tombi",
            "linux_x86_64": "@tbhb_rules_tombi_linux_x86_64//:tombi",
            "macos_arm64": "@tbhb_rules_tombi_macos_arm64//:tombi",
            "windows_x86_64": "@tbhb_rules_tombi_windows_x86_64//:tombi.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_vale",
        tool = "vale",
        binaries = {
            "linux_arm64": "@tbhb_rules_vale_linux_arm64//:vale",
            "linux_x86_64": "@tbhb_rules_vale_linux_x86_64//:vale",
            "macos_arm64": "@tbhb_rules_vale_macos_arm64//:vale",
            "windows_x86_64": "@tbhb_rules_vale_windows_x86_64//:vale.exe",
        },
    )

    _tool_hub(
        name = "tbhb_rules_zizmor",
        tool = "zizmor",
        binaries = {
            "linux_arm64": "@tbhb_rules_zizmor_linux_arm64//:zizmor",
            "linux_x86_64": "@tbhb_rules_zizmor_linux_x86_64//:zizmor",
            "macos_arm64": "@tbhb_rules_zizmor_macos_arm64//:zizmor",
            "windows_x86_64": "@tbhb_rules_zizmor_windows_x86_64//:zizmor.exe",
        },
    )

    return mctx.extension_metadata(reproducible = True)

tools = module_extension(
    implementation = _tools_impl,
    doc = "The pinned tool binaries and their per-tool hub repositories.",
)
