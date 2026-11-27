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
load(":hub.bzl", _EXPORT = "EXPORT", _EXPORT_TREE = "EXPORT_TREE", _tool_files_hub = "tool_files_hub", _tool_hub = "tool_hub")

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
        name = "tbhb_rules_cue_macos_arm64",
        build_file_content = _EXPORT.format("cue"),
        sha256 = "64921403f012a97f89494c03605db2fbf7d9daa77dc2631819ac4406cb2e8074",
        url = "https://github.com/cue-lang/cue/releases/download/v0.17.1/cue_v0.17.1_darwin_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_cue_linux_x86_64",
        build_file_content = _EXPORT.format("cue"),
        sha256 = "a39b0c97695069d95d276d99be0f5dbabb081d801bfdc9ba49b76efaf94e2369",
        url = "https://github.com/cue-lang/cue/releases/download/v0.17.1/cue_v0.17.1_linux_amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_cue_linux_arm64",
        build_file_content = _EXPORT.format("cue"),
        sha256 = "0d729be30d52c952ca38fc9dcb692caa09d8463fa0b64df5781312779183fbcd",
        url = "https://github.com/cue-lang/cue/releases/download/v0.17.1/cue_v0.17.1_linux_arm64.tar.gz",
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
        sha256 = "a882ec6882416b57d212a22bac845ae27944f96cf73453a864f6a12c17863a79",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.1/dugite-native-v2.56.1-238326e-macOS-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_git_linux_x86_64",
        build_file_content = _EXPORT_TREE.format("bin/git-wrapper"),
        patch_cmds = git_patch_cmds,
        sha256 = "e5bc3e8e80b57a5bcd8da18d59b23f5b39533d19019ac1d50b0bd34f051d111d",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.1/dugite-native-v2.56.1-238326e-ubuntu-x64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_git_linux_arm64",
        build_file_content = _EXPORT_TREE.format("bin/git-wrapper"),
        patch_cmds = git_patch_cmds,
        sha256 = "8626f036e1235f5b209d8331c368d85a9790988fb21a443e5f61662a178abcb6",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.1/dugite-native-v2.56.1-238326e-ubuntu-arm64.tar.gz",
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
        sha256 = "7caeb6c0264970479c0c0185c936463255b7b6048e675a647dfbebab337f91fe",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.5/rumdl-v0.3.5-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_rumdl_linux_x86_64",
        build_file_content = _EXPORT.format("rumdl"),
        sha256 = "1f7f569ce1978ec1ed21528234d01c9bd2041ed7265d2677f4d845177114f452",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.5/rumdl-v0.3.5-x86_64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_rumdl_linux_arm64",
        build_file_content = _EXPORT.format("rumdl"),
        sha256 = "3adec6780fe6e2295d634ff06601104e3e775005cdf98dd19b1817711f801502",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.5/rumdl-v0.3.5-aarch64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_ryl_macos_arm64",
        build_file_content = _EXPORT.format("ryl"),
        sha256 = "d3d0010227870a6e4b2764eb26cff52efe0570508f2c52369d17eae3889575eb",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.30.0/ryl-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_ryl_linux_x86_64",
        build_file_content = _EXPORT.format("ryl"),
        sha256 = "37ee3c236005117886949cb413b467a9f4ec06072e2233a1727222b06e54ea3e",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.30.0/ryl-x86_64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_ryl_linux_arm64",
        build_file_content = _EXPORT.format("ryl"),
        sha256 = "2e4a765434d63986c858678df0573349da44abc162b7b698a4395e5b586a1e10",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.30.0/ryl-aarch64-unknown-linux-gnu.tar.gz",
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
        sha256 = "4e7daae9197910fe3717d241e5ca85cafd0f7f0ead988056fdd0b2cf2a447600",
        strip_prefix = "tombi-cli-1.11.3-aarch64-apple-darwin",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.11.3/tombi-cli-1.11.3-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_tombi_linux_x86_64",
        build_file_content = _EXPORT.format("tombi"),
        sha256 = "36672279d05f093455f01fa5a2799a8cc2162a9195cbbb23f0f8d1107d0de497",
        strip_prefix = "tombi-cli-1.11.3-x86_64-unknown-linux-musl",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.11.3/tombi-cli-1.11.3-x86_64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_tombi_linux_arm64",
        build_file_content = _EXPORT.format("tombi"),
        sha256 = "083614471a69e15f147ba68c96fe1e3ea02e8efe38d6bcdb4606b5a37ab8758a",
        strip_prefix = "tombi-cli-1.11.3-aarch64-unknown-linux-musl",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.11.3/tombi-cli-1.11.3-aarch64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_vale_macos_arm64",
        build_file_content = _EXPORT.format("vale"),
        sha256 = "b5362c16d2c95db9d773078b957f5bd59cef27d05dac34c5248a93fed130e9f1",
        url = "https://github.com/vale-cli/vale/releases/download/v3.28.1/vale_3.28.1_macOS_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_vale_linux_x86_64",
        build_file_content = _EXPORT.format("vale"),
        sha256 = "068954ad869ebec24b8dec6ebcd1cbb1fd5f5a83e966a35baedfae8b2cdc093a",
        url = "https://github.com/vale-cli/vale/releases/download/v3.28.1/vale_3.28.1_Linux_64-bit.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_vale_linux_arm64",
        build_file_content = _EXPORT.format("vale"),
        sha256 = "af0ca36ec6133ba20093295591e43ed2823b2632520d1f3811293aa4cbe758f2",
        url = "https://github.com/vale-cli/vale/releases/download/v3.28.1/vale_3.28.1_Linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_zizmor_macos_arm64",
        build_file_content = _EXPORT.format("zizmor"),
        sha256 = "68516d45723aac36e9c87c47d56e8418009fcb919c6ceb44514d85b9d0c1c011",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.33.1/zizmor-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_zizmor_linux_x86_64",
        build_file_content = _EXPORT.format("zizmor"),
        sha256 = "3e6a301c7a820a2501915f5a9de8c0486da82bdec7965f068477538a98743d43",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.33.1/zizmor-x86_64-unknown-linux-gnu.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_zizmor_linux_arm64",
        build_file_content = _EXPORT.format("zizmor"),
        sha256 = "aa487c792a7cbbe86e4f8dccd3b66de33b3b51813c090aaa0842d7ea08a3fc35",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.33.1/zizmor-aarch64-unknown-linux-gnu.tar.gz",
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
        name = "tbhb_rules_cue_windows_x86_64",
        build_file_content = _EXPORT.format("cue.exe"),
        sha256 = "9f15378dc52b9a1bb6fa1755adc0410c9f17f330a621b784a5b31fdbc91c6d7a",
        url = "https://github.com/cue-lang/cue/releases/download/v0.17.1/cue_v0.17.1_windows_amd64.zip",
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
        sha256 = "e9fa2c78952aa2c2154c26dbd4999f93269896e9fc902fa9fe840412d4ffdb04",
        url = "https://github.com/desktop/dugite-native/releases/download/v2.56.1/dugite-native-v2.56.1-238326e-windows-x64.tar.gz",
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
        sha256 = "ff40c7b64f8c67e5a39d5734837d2fc9984c0da436e4cc79bb72a08cea413b2d",
        url = "https://github.com/rvben/rumdl/releases/download/v0.3.5/rumdl-v0.3.5-x86_64-pc-windows-msvc.zip",
    )

    http_archive(
        name = "tbhb_rules_ryl_windows_x86_64",
        build_file_content = _EXPORT.format("ryl.exe"),
        sha256 = "4debe78d5945908c2d561230e3b60c2a960ea153e1d9684a4ecec5a8608d96c9",
        url = "https://github.com/owenlamont/ryl/releases/download/v0.30.0/ryl-x86_64-pc-windows-msvc.zip",
    )

    http_archive(
        name = "tbhb_rules_shellcheck_windows_x86_64",
        build_file_content = _EXPORT.format("shellcheck.exe"),
        sha256 = "8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e",
        url = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.zip",
    )

    # Temporal publishes these four digests in the release's checksums.txt.
    http_archive(
        name = "tbhb_rules_temporal_linux_arm64",
        build_file_content = _EXPORT.format("temporal"),
        sha256 = "2f748e9411b37c9cabb57f1f08e37765388c12b5534432c7aea28b593df9145d",
        url = "https://github.com/temporalio/cli/releases/download/v1.10.1/temporal_cli_1.10.1_linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_temporal_linux_x86_64",
        build_file_content = _EXPORT.format("temporal"),
        sha256 = "4c1500e2ce2d4de136e5fe8852d9b7f82eb62f19b6b383b3e0c040519a9d20b1",
        url = "https://github.com/temporalio/cli/releases/download/v1.10.1/temporal_cli_1.10.1_linux_amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_temporal_macos_arm64",
        build_file_content = _EXPORT.format("temporal"),
        sha256 = "94f7f982b26438e8abbde6000ba471b694be6a2413b31f6162f87a9f9c48c738",
        url = "https://github.com/temporalio/cli/releases/download/v1.10.1/temporal_cli_1.10.1_darwin_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_temporal_windows_x86_64",
        build_file_content = _EXPORT.format("temporal.exe"),
        sha256 = "5069cdb76569914305ed7c90e1c8406cd27bcb6c2a822fce201a488c34ab074f",
        url = "https://github.com/temporalio/cli/releases/download/v1.10.1/temporal_cli_1.10.1_windows_amd64.zip",
    )

    http_archive(
        name = "tbhb_rules_tombi_windows_x86_64",
        build_file_content = _EXPORT.format("tombi.exe"),
        sha256 = "b6b2d9e6419216aaa0b8e74a5c81c48335cb193d6eb87f50a7d77468bce10073",
        url = "https://github.com/tombi-toml/tombi/releases/download/v1.11.3/tombi-cli-1.11.3-x86_64-pc-windows-msvc.zip",
    )

    http_archive(
        name = "tbhb_rules_vale_windows_x86_64",
        build_file_content = _EXPORT.format("vale.exe"),
        sha256 = "5ad37282f16f3903bb2ec89a7b7b9e718ef838577ffc1657f892a0068cd9b0f3",
        url = "https://github.com/vale-cli/vale/releases/download/v3.28.1/vale_3.28.1_Windows_64-bit.zip",
    )

    http_archive(
        name = "tbhb_rules_zizmor_windows_x86_64",
        build_file_content = _EXPORT.format("zizmor.exe"),
        sha256 = "f02ebeedf651da468b4de19d31f0609050af74e11be41dc46d82e355cf44f68b",
        url = "https://github.com/zizmorcore/zizmor/releases/download/v1.33.1/zizmor-x86_64-pc-windows-msvc.zip",
    )

    http_file(
        name = "tbhb_rules_shfmt_windows_x86_64",
        downloaded_file_path = "shfmt.exe",
        executable = True,
        sha256 = "13629ce28442ca80b6b5a819f7574ab39e1c28c6e26734ca816c9714e04851df",
        url = "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_windows_amd64.exe",
    )

    http_archive(
        name = "tbhb_rules_scc_macos_arm64",
        build_file_content = _EXPORT.format("scc"),
        sha256 = "7201c7aa4aace058d43308462cba72adb18f6094c08c0741727455976d0a0747",
        url = "https://github.com/boyter/scc/releases/download/v4.1.0/scc_Darwin_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_scc_linux_x86_64",
        build_file_content = _EXPORT.format("scc"),
        sha256 = "c7328436d3027f4357d3d7853f7dc3ac2bbcb4ca08f1adad91a27c593884079b",
        url = "https://github.com/boyter/scc/releases/download/v4.1.0/scc_Linux_x86_64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_scc_linux_arm64",
        build_file_content = _EXPORT.format("scc"),
        sha256 = "6e0d2a1f8d3540ba7df185477dec40bb7340f1b214bfd303147de5cad2bd7b8b",
        url = "https://github.com/boyter/scc/releases/download/v4.1.0/scc_Linux_arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_scc_windows_x86_64",
        build_file_content = _EXPORT.format("scc.exe"),
        sha256 = "4a433984f45ff29c94eeb3af6db5b511c58f5bf74063dccedafcbf473cb8ff31",
        url = "https://github.com/boyter/scc/releases/download/v4.1.0/scc_Windows_x86_64.zip",
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
        name = "tbhb_rules_cue",
        tool = "cue",
        binaries = {
            "linux_arm64": "@tbhb_rules_cue_linux_arm64//:cue",
            "linux_x86_64": "@tbhb_rules_cue_linux_x86_64//:cue",
            "macos_arm64": "@tbhb_rules_cue_macos_arm64//:cue",
            "windows_x86_64": "@tbhb_rules_cue_windows_x86_64//:cue.exe",
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
        name = "tbhb_rules_temporal",
        tool = "temporal",
        binaries = {
            "linux_arm64": "@tbhb_rules_temporal_linux_arm64//:temporal",
            "linux_x86_64": "@tbhb_rules_temporal_linux_x86_64//:temporal",
            "macos_arm64": "@tbhb_rules_temporal_macos_arm64//:temporal",
            "windows_x86_64": "@tbhb_rules_temporal_windows_x86_64//:temporal.exe",
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

    _tool_hub(
        name = "tbhb_rules_scc",
        tool = "scc",
        binaries = {
            "linux_arm64": "@tbhb_rules_scc_linux_arm64//:scc",
            "linux_x86_64": "@tbhb_rules_scc_linux_x86_64//:scc",
            "macos_arm64": "@tbhb_rules_scc_macos_arm64//:scc",
            "windows_x86_64": "@tbhb_rules_scc_windows_x86_64//:scc.exe",
        },
    )

    # Structurizr and PlantUML run on the pinned JRE, with no system Java.
    # These archives stay outside the source tree; their own license notices
    # travel with their files, like the other downloaded tools.
    # Liberation Sans 2.1.5 is SIL-OFL-1.1 (archive LICENSE, Google/Red Hat).
    # Keep all four styles and the upstream notice together.
    http_archive(
        name = "tbhb_rules_liberation_fonts_archive",
        build_file_content = "filegroup(name = \"fonts\", srcs = glob([\"LiberationSans-*.ttf\"]) + [\"LICENSE\"], visibility = [\"//visibility:public\"])",
        sha256 = "7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0",
        strip_prefix = "liberation-fonts-ttf-2.1.5",
        url = "https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz",
    )

    _tool_files_hub(
        name = "tbhb_rules_liberation_fonts",
        tool = "fonts",
        files = {
            "linux_arm64": "@tbhb_rules_liberation_fonts_archive//:fonts",
            "linux_x86_64": "@tbhb_rules_liberation_fonts_archive//:fonts",
            "macos_arm64": "@tbhb_rules_liberation_fonts_archive//:fonts",
            "macos_x86_64": "@tbhb_rules_liberation_fonts_archive//:fonts",
        },
    )

    http_archive(
        name = "tbhb_rules_structurizr_cli_archive",
        build_file_content = "filegroup(name = \"cli\", srcs = glob([\"lib/*.jar\"]), visibility = [\"//visibility:public\"])",
        sha256 = "f5365a463fc44d539ed19bec00c48ba1e1ecda0ccfd1ba40d2e7472d264eb79a",
        url = "https://github.com/structurizr/cli/releases/download/v2025.11.09/structurizr-cli.zip",
    )

    http_file(
        name = "tbhb_rules_plantuml_jar",
        downloaded_file_path = "plantuml.jar",
        sha256 = "30a66b81a16127fd3ec560992f31964fe9ae3f1233c614ef4558a4558a21489e",
        url = "https://github.com/plantuml/plantuml/releases/download/v1.2026.10/plantuml-mit-1.2026.10.jar",
    )

    http_archive(
        name = "tbhb_rules_jre_linux_x86_64",
        build_file_content = _EXPORT_TREE.format("bin/java"),
        sha256 = "a535a1df9c6284d9618872984e026ae0352d1f7e9e0605425c0e6114f47351dd",
        strip_prefix = "jdk-21.0.13+9-jre",
        url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_linux_hotspot_21.0.13_9.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_jre_linux_arm64",
        build_file_content = _EXPORT_TREE.format("bin/java"),
        sha256 = "b1734db7ade49c3f6acc6ae06233b8c2dd90e3e2f00f67000ae1c972aaa64d8c",
        strip_prefix = "jdk-21.0.13+9-jre",
        url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_aarch64_linux_hotspot_21.0.13_9.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_jre_macos_x86_64",
        build_file_content = _EXPORT_TREE.format("bin/java"),
        sha256 = "c909674b1c10c261b9a3fb7e9c0efebd303e33f88a4fe84be7135b5e2d711f89",
        strip_prefix = "jdk-21.0.13+9-jre/Contents/Home",
        url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_mac_hotspot_21.0.13_9.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_jre_macos_arm64",
        build_file_content = _EXPORT_TREE.format("bin/java"),
        sha256 = "225bab0a09491ef06835488cd942f5d2befa9a0410a2484f0c8bbcf7506ec09a",
        strip_prefix = "jdk-21.0.13+9-jre/Contents/Home",
        url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_aarch64_mac_hotspot_21.0.13_9.tar.gz",
    )

    _tool_hub(
        name = "tbhb_rules_jre",
        tool = "java",
        binaries = {
            "linux_arm64": "@tbhb_rules_jre_linux_arm64//:bin/java",
            "linux_x86_64": "@tbhb_rules_jre_linux_x86_64//:bin/java",
            "macos_arm64": "@tbhb_rules_jre_macos_arm64//:bin/java",
            "macos_x86_64": "@tbhb_rules_jre_macos_x86_64//:bin/java",
        },
        data = {
            "linux_arm64": "@tbhb_rules_jre_linux_arm64//:tree",
            "linux_x86_64": "@tbhb_rules_jre_linux_x86_64//:tree",
            "macos_arm64": "@tbhb_rules_jre_macos_arm64//:tree",
            "macos_x86_64": "@tbhb_rules_jre_macos_x86_64//:tree",
        },
    )

    _tool_files_hub(
        name = "tbhb_rules_structurizr_cli",
        tool = "structurizr",
        files = {
            "linux_arm64": "@tbhb_rules_structurizr_cli_archive//:cli",
            "linux_x86_64": "@tbhb_rules_structurizr_cli_archive//:cli",
            "macos_arm64": "@tbhb_rules_structurizr_cli_archive//:cli",
            "macos_x86_64": "@tbhb_rules_structurizr_cli_archive//:cli",
        },
    )

    _tool_files_hub(
        name = "tbhb_rules_plantuml",
        tool = "plantuml",
        files = {
            "linux_arm64": "@tbhb_rules_plantuml_jar//file:plantuml.jar",
            "linux_x86_64": "@tbhb_rules_plantuml_jar//file:plantuml.jar",
            "macos_arm64": "@tbhb_rules_plantuml_jar//file:plantuml.jar",
            "macos_x86_64": "@tbhb_rules_plantuml_jar//file:plantuml.jar",
        },
    )

    return mctx.extension_metadata(reproducible = True)

tools = module_extension(
    implementation = _tools_impl,
    doc = "The pinned tool binaries and their per-tool hub repositories.",
)
