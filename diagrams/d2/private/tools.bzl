# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`tools`: the prebuilt tool binaries and the font this module renders with.

The same shape as @tbhb_rules//pins: every binary is a literal
`http_archive` call, one per tool and platform, so Renovate's bazel manager
can move a version by rewriting the URL and recomputing its sha256, and each
tool has a hub, `tbhb_rules_<tool>` (`tbhb_rules_d2_cli` for d2, since
`tbhb_rules_d2` is this module), whose `//:<tool>` target picks the binary
for the target platform. A consumer replaces one with `override_repo`:

    tools = use_extension("@tbhb_rules_d2//private:tools.bzl", "tools")
    override_repo(tools, tbhb_rules_d2_cli = "my_d2")

The fonts are Source Sans Pro and Source Code Pro, the families the PNG's
text is rewritten to (resvg skips the SVG's embedded `@font-face` fonts);
`//:ttf` is each one's TTF directory.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@tbhb_rules//pins:hub.bzl", "EXPORT", "tool_hub")

_FONT = """filegroup(
    name = "ttf",
    srcs = glob(["TTF/*.ttf"]),
    visibility = ["//visibility:public"],
)"""

def _tools_impl(module_ctx):
    http_archive(
        name = "tbhb_rules_d2_cli_macos_arm64",
        build_file_content = EXPORT.format("bin/d2"),
        sha256 = "eaf6c0c143e56dd9fa97bfb6df25ea9c1ebce40245f056a0768cf1a6c15d3064",
        strip_prefix = "d2-v0.9.0",
        url = "https://github.com/d2lang/d2/releases/download/v0.9.0/d2-v0.9.0-macos-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_d2_cli_linux_x86_64",
        build_file_content = EXPORT.format("bin/d2"),
        sha256 = "5669ddc46b99e942cc96078f4a4e36d5e62103348f4c05179ede27802fdd87a9",
        strip_prefix = "d2-v0.9.0",
        url = "https://github.com/d2lang/d2/releases/download/v0.9.0/d2-v0.9.0-linux-amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_d2_cli_linux_arm64",
        build_file_content = EXPORT.format("bin/d2"),
        sha256 = "ac2c028697199479acb321db1e3d68caee9f2ba492ed73caa3cd13f3829bf913",
        strip_prefix = "d2-v0.9.0",
        url = "https://github.com/d2lang/d2/releases/download/v0.9.0/d2-v0.9.0-linux-arm64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_d2_cli_windows_x86_64",
        build_file_content = EXPORT.format("bin/d2.exe"),
        sha256 = "5f63b643de8f5a6dfb922d172e1b5496e4caf47497c33c4427cf1127f28c340f",
        strip_prefix = "d2-v0.9.0",
        url = "https://github.com/d2lang/d2/releases/download/v0.9.0/d2-v0.9.0-windows-amd64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_resvg_macos_arm64",
        build_file_content = EXPORT.format("resvg"),
        sha256 = "8155b569f2b93723ba3645b53536eead3b591c8faf62bdaafd3033ba37838837",
        url = "https://github.com/linebender/resvg/releases/download/v0.50.0/resvg-macos-aarch64.zip",
    )

    http_archive(
        name = "tbhb_rules_resvg_linux_x86_64",
        build_file_content = EXPORT.format("resvg"),
        sha256 = "5d1c9ffd43c82fb802d92cef8100055c612cd3e248d5a787c20079293a456e21",
        url = "https://github.com/linebender/resvg/releases/download/v0.50.0/resvg-linux-x86_64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_resvg_linux_arm64",
        build_file_content = EXPORT.format("resvg"),
        sha256 = "b197bf704c9da5d572ae565c799727da3067dffacaf32a2476c8143af90e2f9c",
        url = "https://github.com/linebender/resvg/releases/download/v0.50.0/resvg-linux-aarch64.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_resvg_windows_x86_64",
        build_file_content = EXPORT.format("resvg.exe"),
        sha256 = "e4817e40ac63d3eb5c9e5762526cf6cc91f0cc108de38cd09dd60be765184efd",
        url = "https://github.com/linebender/resvg/releases/download/v0.50.0/resvg-win-x86_64.zip",
    )

    http_archive(
        name = "tbhb_rules_oxipng_macos_arm64",
        build_file_content = EXPORT.format("oxipng"),
        sha256 = "7039fcfc78e8aa1ed2b57d848057a0296f082e92b3e1807ac65402d10d926764",
        strip_prefix = "oxipng-10.2.1-aarch64-apple-darwin",
        url = "https://github.com/oxipng/oxipng/releases/download/v10.2.1/oxipng-10.2.1-aarch64-apple-darwin.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_oxipng_linux_x86_64",
        build_file_content = EXPORT.format("oxipng"),
        sha256 = "1813750ef592c5350ca79c88f98b2c0876d05c826dc7156245256d4255c1ad17",
        strip_prefix = "oxipng-10.2.1-x86_64-unknown-linux-musl",
        url = "https://github.com/oxipng/oxipng/releases/download/v10.2.1/oxipng-10.2.1-x86_64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_oxipng_linux_arm64",
        build_file_content = EXPORT.format("oxipng"),
        sha256 = "ff21aa2a005b324c8dfbdf13cd2f469fb6728b27dacded82635824ecd12e3b35",
        strip_prefix = "oxipng-10.2.1-aarch64-unknown-linux-musl",
        url = "https://github.com/oxipng/oxipng/releases/download/v10.2.1/oxipng-10.2.1-aarch64-unknown-linux-musl.tar.gz",
    )

    http_archive(
        name = "tbhb_rules_oxipng_windows_x86_64",
        build_file_content = EXPORT.format("oxipng.exe"),
        sha256 = "7e940f83ee46874b73f53031f96a15834cb70b220af27391fb06fe7b4dd798e1",
        strip_prefix = "oxipng-10.2.1-x86_64-pc-windows-msvc",
        url = "https://github.com/oxipng/oxipng/releases/download/v10.2.1/oxipng-10.2.1-x86_64-pc-windows-msvc.zip",
    )

    # 2.045R is the last release of the Source Sans Pro family; later
    # releases are Source Sans 3, another family name. Renovate leaves this
    # pin alone (.github/renovate.json5).
    http_archive(
        name = "tbhb_rules_source_sans_pro",
        build_file_content = _FONT,
        sha256 = "5f090b821e117f452ef399c3c1b8b244c1647728a1e901c4d167cbf7fc298ab6",
        strip_prefix = "source-sans-pro-2.045R-ro-1.095R-it",
        url = "https://github.com/adobe-fonts/source-sans/releases/download/2.045R-ro/1.095R-it/source-sans-pro-2.045R-ro-1.095R-it.zip",
    )

    # d2's monospace font, for code, class and sql_table text. Renovate
    # leaves this pin alone too: the bazel manager would misread the tag.
    http_archive(
        name = "tbhb_rules_source_code_pro",
        build_file_content = _FONT,
        sha256 = "0c85bac90d15c040b82939aa92bc8404420fccc02e37bbcb9c93a7f21abb52c6",
        url = "https://github.com/adobe-fonts/source-code-pro/releases/download/2.042R-u/1.062R-i/1.026R-vf/TTF-source-code-pro-2.042R-u_1.062R-i.zip",
    )

    tool_hub(
        name = "tbhb_rules_d2_cli",
        tool = "d2",
        binaries = {
            "linux_arm64": "@tbhb_rules_d2_cli_linux_arm64//:bin/d2",
            "linux_x86_64": "@tbhb_rules_d2_cli_linux_x86_64//:bin/d2",
            "macos_arm64": "@tbhb_rules_d2_cli_macos_arm64//:bin/d2",
            "windows_x86_64": "@tbhb_rules_d2_cli_windows_x86_64//:bin/d2.exe",
        },
    )

    tool_hub(
        name = "tbhb_rules_resvg",
        tool = "resvg",
        binaries = {
            "linux_arm64": "@tbhb_rules_resvg_linux_arm64//:resvg",
            "linux_x86_64": "@tbhb_rules_resvg_linux_x86_64//:resvg",
            "macos_arm64": "@tbhb_rules_resvg_macos_arm64//:resvg",
            "windows_x86_64": "@tbhb_rules_resvg_windows_x86_64//:resvg.exe",
        },
    )

    tool_hub(
        name = "tbhb_rules_oxipng",
        tool = "oxipng",
        binaries = {
            "linux_arm64": "@tbhb_rules_oxipng_linux_arm64//:oxipng",
            "linux_x86_64": "@tbhb_rules_oxipng_linux_x86_64//:oxipng",
            "macos_arm64": "@tbhb_rules_oxipng_macos_arm64//:oxipng",
            "windows_x86_64": "@tbhb_rules_oxipng_windows_x86_64//:oxipng.exe",
        },
    )

    return module_ctx.extension_metadata(reproducible = True)

tools = module_extension(
    implementation = _tools_impl,
    doc = "The tools of this module: d2, resvg and oxipng (prebuilt), and the Source Sans Pro and Source Code Pro fonts.",
)
