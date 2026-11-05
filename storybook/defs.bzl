# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_storybook.

`FRAMEWORKS` maps each name the rules' `framework` takes to the pinned
framework package behind it.
"""

load(
    "//private:storybook.bzl",
    _FRAMEWORKS = "FRAMEWORKS",
    _storybook_build = "storybook_build",
    _storybook_dev = "storybook_dev",
    _storybook_test = "storybook_test",
)

FRAMEWORKS = _FRAMEWORKS
storybook_build = _storybook_build
storybook_dev = _storybook_dev
storybook_test = _storybook_test
