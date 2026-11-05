# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""One Storybook fixture: its build, tests and dev server."""

load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@tbhb_rules_storybook//:defs.bzl", "storybook_build", "storybook_dev", "storybook_test")

NOT_WINDOWS = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
})

def storybook_fixture(framework, heading, refusals = False):
    """This package's Storybook for `framework`, built, tested and served.

    Args:
        framework: The framework the rules take.
        heading: The heading the Greeting story renders.
        refusals: Whether the dev test also proves the dev server's refusals.
    """
    srcs = native.glob([".storybook/**", "src/**", "package.json"])

    storybook_build(
        name = "dist",
        srcs = srcs,
        framework = framework,
        node_modules = "//:node_modules",
    )

    # The built Storybook served from the base path a Pages site gives it.
    js_test(
        name = "dist_test",
        args = [
            "$(rootpath :dist)",
            "/storybook/{}/".format(framework),
            "greeting--static",
            "'{}'".format(heading),
        ],
        data = [
            ":dist",
            "//:dist_test",
            "//:node_modules/playwright-core",
            "@tbhb_rules_playwright//:browsers_path",
            "@tbhb_rules_playwright//:chromium",
        ],
        entry_point = "//:dist_test",
        env = {
            "TBHB_PLAYWRIGHT_BROWSERS": "$(rlocationpath @tbhb_rules_playwright//:chromium)",
            "TBHB_PLAYWRIGHT_HELPER": "$(rlocationpath @tbhb_rules_playwright//:browsers_path)",
        },
        patch_node_fs = False,
        target_compatible_with = NOT_WINDOWS,
    )

    storybook_test(
        name = "storybook_test",
        srcs = srcs,
        framework = framework,
        node_modules = "//:node_modules",
    )

    storybook_dev(
        name = "dev",
        framework = framework,
        node_modules = "//:node_modules",
    )

    # The dev server, run as `bazel run` would run it, over a copy of the
    # Storybook in a workspace, under the base path the reverse proxy gives it.
    files = ["//{}:{}".format(native.package_name(), f) for f in srcs]
    js_test(
        name = "dev_test",
        args = (["--refusals"] if refusals else []) + [
            "$(rootpath :dev)",
            "$(rootpath :dist_launcher)",
            "/storybook/{}/".format(framework),
        ] + ["$(rootpath {})".format(f) for f in files],
        data = [
            ":dev",
            ":dist_launcher",
            "//:dev_test",
        ] + files,
        entry_point = "//:dev_test",
        target_compatible_with = NOT_WINDOWS,
    )
