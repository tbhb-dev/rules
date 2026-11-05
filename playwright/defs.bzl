# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_playwright.

`@tbhb_rules_playwright//:chromium` is the current platform's pinned Chromium
headless shell. Its default output is one file holding the browsers'
PLAYWRIGHT_BROWSERS_PATH directory relative to the runfiles root, and its
runfiles are the browsers. A test takes it in `data` and passes the file's
location in, such as

    data = ["@tbhb_rules_playwright//:chromium"],
    env = {"BROWSERS": "$(rlocationpath @tbhb_rules_playwright//:chromium)"},

then sets PLAYWRIGHT_BROWSERS_PATH to the runfiles root joined with the
file's contents before Playwright starts. A rule reads the same directory
from PlaywrightBrowsersInfo.

`@tbhb_rules_playwright//:browsers_path` is a JavaScript module whose
`browsersPath(pathFile)` does that last step: given the file's location, it
returns the browsers' real directory, which is the form to set. The runfiles
tree links each file, and the path to the browser through it can run past
Windows' MAX_PATH, where CreateProcess then fails; under the real directory
the path is far shorter. It throws, naming the path, when the browsers
aren't there.

On Windows, Bazel makes no runfiles tree unless asked, and the browsers must
sit in one: a consumer sets `common:windows --enable_runfiles` (with
`startup --windows_enable_symlinks`, so the tree holds links, not copies), as
this module's e2e smoke module does. The target is compatible with linux
arm64 and x86_64, macOS arm64 and Windows x86_64, and incompatible
elsewhere, so a test that depends on it is skipped there.

The browsers belong to playwright-core PLAYWRIGHT_VERSION, which a consumer's
own `playwright` or `playwright-core` must match: another release looks for
another revision directory and doesn't find it.
"""

load("//private:browsers.bzl", _CHROMIUM_HEADLESS_SHELL_REVISION = "CHROMIUM_HEADLESS_SHELL_REVISION", _PLAYWRIGHT_VERSION = "PLAYWRIGHT_VERSION")
load("//private:browsers_rule.bzl", _PlaywrightBrowsersInfo = "PlaywrightBrowsersInfo")

CHROMIUM_HEADLESS_SHELL_REVISION = _CHROMIUM_HEADLESS_SHELL_REVISION
PLAYWRIGHT_VERSION = _PLAYWRIGHT_VERSION
PlaywrightBrowsersInfo = _PlaywrightBrowsersInfo
