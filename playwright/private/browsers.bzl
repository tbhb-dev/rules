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
PLAYWRIGHT_VERSION = "1.65.0"
CHROMIUM_HEADLESS_SHELL_REVISION = "1254"
CHROMIUM_HEADLESS_SHELL_VERSION = "158.0.8127.18"

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
        sha256 = "b136462898353d94c7fab50f9cdaa6d8f0d4c190153916936aa0a03353a26bf2",
        url = "https://cdn.playwright.dev/builds/cft/158.0.8127.18/linux-arm64/chrome-headless-shell-linux-arm64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_linux_x86_64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "18352d22cb0cdf520cbff2ad8c41391f0e02a72886cb53b0fde4bdfc4bd075d6",
        url = "https://cdn.playwright.dev/builds/cft/158.0.8127.18/linux64/chrome-headless-shell-linux64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_macos_arm64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "f34261d2aad94fb71b336597acabf20166ee5a2f14926c731f33d04c5da6cd3f",
        url = "https://cdn.playwright.dev/builds/cft/158.0.8127.18/mac-arm64/chrome-headless-shell-mac-arm64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_windows_x86_64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "fdd3721ad0299ddd419d170ce8ab89aecf8631d157b85215474b4a70c8dcd061",
        url = "https://cdn.playwright.dev/builds/cft/158.0.8127.18/win64/chrome-headless-shell-win64.zip",
    )

    return mctx.extension_metadata(reproducible = True)

browsers = module_extension(
    implementation = _browsers_impl,
    doc = "The pinned Chromium headless shell archives, one per platform.",
)
