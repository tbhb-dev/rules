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
PLAYWRIGHT_VERSION = "1.65.1"
CHROMIUM_HEADLESS_SHELL_REVISION = "1255"
CHROMIUM_HEADLESS_SHELL_VERSION = "159.0.8154.6"

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
        sha256 = "e1262e9f4f244c441dcb54aa0e9abe4cf7b266ab02dc666fd975bd55aba9b3dc",
        url = "https://cdn.playwright.dev/builds/cft/159.0.8154.6/linux-arm64/chrome-headless-shell-linux-arm64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_linux_x86_64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "77a6442fd3c8acd3bef9e1067fc26f5ef464277d22f0e8cb58dc3e4077a3e458",
        url = "https://cdn.playwright.dev/builds/cft/159.0.8154.6/linux64/chrome-headless-shell-linux64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_macos_arm64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "b08e7beaf02a19e2ee5ed6955f9c3853ab9176cd5bb57ba87afbb82e9f81cc29",
        url = "https://cdn.playwright.dev/builds/cft/159.0.8154.6/mac-arm64/chrome-headless-shell-mac-arm64.zip",
    )

    http_archive(
        name = "tbhb_rules_playwright_chromium_headless_shell_windows_x86_64",
        add_prefix = _PREFIX,
        build_file_content = _BUILD,
        sha256 = "5db6a6948e6d1299ea3bc87c420d467bf343feae186a316921c930ce02056af5",
        url = "https://cdn.playwright.dev/builds/cft/159.0.8154.6/win64/chrome-headless-shell-win64.zip",
    )

    return mctx.extension_metadata(reproducible = True)

browsers = module_extension(
    implementation = _browsers_impl,
    doc = "The pinned Chromium headless shell archives, one per platform.",
)
