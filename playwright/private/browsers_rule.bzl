# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The rule behind @tbhb_rules_playwright//:chromium."""

load(":browsers.bzl", "CHROMIUM_HEADLESS_SHELL_REVISION", "PLAYWRIGHT_VERSION")

# Internal: consumers load //:defs.bzl.
visibility("//...")

PlaywrightBrowsersInfo = provider(
    doc = "Where a pinned browser set sits in the runfiles tree.",
    fields = {
        "browsers_path": "The PLAYWRIGHT_BROWSERS_PATH directory, as a path relative to the runfiles root (an rlocation path).",
        "chromium_headless_shell_revision": "The revision Playwright looks for, as in browsers.json.",
        "playwright_version": "The playwright-core release the browsers belong to.",
    },
)

def _playwright_browsers_impl(ctx):
    # srcs is never empty: //:chromium's select gives every compatible
    # platform its archive, and its default arm is incompatible, so Bazel
    # skips the target before this runs. Its files all come from that one
    # archive repository, whose root is the PLAYWRIGHT_BROWSERS_PATH
    # directory; a repository's rlocation path is its canonical name.
    files = ctx.files.srcs
    browsers_path = files[0].owner.repo_name

    # A one-line file holding that path, so a test reaches the browsers with
    # `$(rlocationpath)` on this target and its runfiles library.
    path_file = ctx.actions.declare_file(ctx.label.name + ".browsers_path")
    ctx.actions.write(path_file, browsers_path + "\n")
    return [
        DefaultInfo(
            files = depset([path_file]),
            runfiles = ctx.runfiles(files = files + [path_file]),
        ),
        PlaywrightBrowsersInfo(
            browsers_path = browsers_path,
            chromium_headless_shell_revision = CHROMIUM_HEADLESS_SHELL_REVISION,
            playwright_version = PLAYWRIGHT_VERSION,
        ),
    ]

playwright_browsers = rule(
    implementation = _playwright_browsers_impl,
    doc = "The current platform's pinned browsers, with their PLAYWRIGHT_BROWSERS_PATH.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "The files of one browser archive repository.",
        ),
    },
    provides = [PlaywrightBrowsersInfo],
)
