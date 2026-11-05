# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The pinned Chromium headless shell behind @tbhb_rules_playwright//:chromium.

Every archive is a literal `http_archive` call, one per platform, as in
tbhb_rules' pins. Playwright finds a browser by its revision, so each archive
unpacks under `chromium_headless_shell-<revision>/`, beside the platform's
own top directory (`chrome-headless-shell-<platform>/`), which is the layout
`playwright install` writes under PLAYWRIGHT_BROWSERS_PATH.

The URLs carry the browser version and the directories the revision, both
from browsers.json in playwright-core at PLAYWRIGHT_VERSION. A Playwright
bump moves all four archives and both constants together: read the new
browsers.json, update the URLs, the sha256s and the constants, and the e2e
smoke module's revision check proves they match its playwright-core.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# The playwright-core release these browsers belong to, and its
# browsers.json entries for chromium-headless-shell.
PLAYWRIGHT_VERSION = "1.64.1"
CHROMIUM_HEADLESS_SHELL_REVISION = "1248"
CHROMIUM_HEADLESS_SHELL_VERSION = "156.0.8078.4"

_PREFIX = "chromium_headless_shell-" + CHROMIUM_HEADLESS_SHELL_REVISION

_BUILD = """filegroup(
    name = "browsers",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "WORKSPACE"]),
    visibility = ["//visibility:public"],
)
"""

def _browsers_impl(mctx):
    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_linux_arm64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "81ab9d4d3c301dc5fdfb6c541b9e6632b16fc819a6a854460f40a76fe2b2c476",
        url = "https://cdn.playwright.dev/builds/cft/156.0.8078.4/linux-arm64/chrome-headless-shell-linux-arm64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_linux_x86_64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "c3e50596aef52c58f8fda3c6b3411c33d34c88b177b3ed1c2243359fd3b8ba20",
        url = "https://cdn.playwright.dev/builds/cft/156.0.8078.4/linux64/chrome-headless-shell-linux64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_macos_arm64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "94e4337b70cbc5638f0935fbc46b9f242bc7416f657e3fbe924baf348404b53d",
        url = "https://cdn.playwright.dev/builds/cft/156.0.8078.4/mac-arm64/chrome-headless-shell-mac-arm64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_windows_x86_64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "5af4c82cf4b351ec4bad4c71dcf938af14fccea8a0eb0d5c2a7b49ccc922698c",
        url = "https://cdn.playwright.dev/builds/cft/156.0.8078.4/win64/chrome-headless-shell-win64.zip",
    )

    return mctx.extension_metadata(reproducible = True)

browsers = module_extension(
    implementation = _browsers_impl,
    doc = "The pinned Chromium headless shell archives, one per platform.",
)
