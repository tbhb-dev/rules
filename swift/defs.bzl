# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_swift.

Macros that wrap rules_swift and rules_apple with this repository's
defaults: a Swift library, an iOS simulator app, a macOS app and their unit
tests, SwiftLint, and the strict compiler flag sets. Everything here needs a
Mac with Xcode, which Bazel doesn't bring (README.md lists which tools use
the host's copy). Nothing signs or uses a provisioning profile.

Strict gates slot in here. A gate is in only when it runs in CI and has a
failing-first proof: a sample that breaks it, and a test that expects the
failure. The README's table has each gate's state. Pending slots:

- coverage: a threshold over the LCOV that `bazelisk coverage` writes;
- mutation: a mutation report over a swift_test's unit;
- analyzer: a static analyzer over Swift sources.
"""

load("@rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("@rules_apple//apple:macos.bzl", "macos_application", "macos_unit_test")
load("@rules_apple//apple/testing/default_runner:ios_xctestrun_runner.bzl", "ios_xctestrun_runner")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("@rules_swift//swift:swift_library.bzl", "swift_library")
load("@rules_swift//swift:swift_test.bzl", "swift_test")

# Named compiler flag sets, passed to swiftc as `copts`. The same list drives
# `tbhb_swift_strict_test`, which type-checks sources with these flags at
# test time, so a gate's failing-first proof can fail at run time.
SWIFT_FLAG_SETS = {
    "default": [],
    "strict": [
        "-warnings-as-errors",
        "-strict-concurrency=complete",
    ],
}

# The sanitizers tbhb_swift_sanitizer_test takes: Bazel's feature names, which
# rules_swift's compile and link actions act on.
SWIFT_SANITIZERS = ["asan", "tsan"]

# What the smoke consumer proved. Consumers override them per target.
IOS_MINIMUM_OS = "17.0"
IOS_SIMULATOR_DEVICE = "iPhone 17"
IOS_SIMULATOR_OS = "27.2"
MACOS_MINIMUM_OS = "14.0"

# The tools' files, from this module, so a consumer pins no tool.
_SWIFTLINT = Label("@tbhb_rules_swiftlint//:swiftlint")
_SWIFTLINT_SCRIPT = Label("//private:swiftlint_test.sh")
_SWIFT_FORMAT_SCRIPT = Label("//private:swift_format_test.sh")
_SWIFTC_TYPECHECK_SCRIPT = Label("//private:swiftc_typecheck_test.sh")

def _flags(flag_set, copts):
    if flag_set not in SWIFT_FLAG_SETS:
        fail("unknown flag_set {!r}; the sets are {}".format(flag_set, sorted(SWIFT_FLAG_SETS)))
    return SWIFT_FLAG_SETS[flag_set] + copts

def _rootpaths(srcs):
    return " ".join(["$(rootpath {})".format(src) for src in srcs])

def tbhb_swift_library(name, srcs, module_name = None, flag_set = "strict", copts = [], **kwargs):
    """A swift_library built under a named flag set.

    Args:
        name: Target name.
        srcs: Swift sources.
        module_name: The Swift module name; defaults to `name`.
        flag_set: A key of SWIFT_FLAG_SETS.
        copts: Extra compiler flags, after the set's.
        **kwargs: Passed to swift_library.
    """
    swift_library(
        name = name,
        srcs = srcs,
        module_name = module_name or name,
        copts = _flags(flag_set, copts),
        **kwargs
    )

def tbhb_swift_test(name, srcs, flag_set = "strict", copts = [], **kwargs):
    """An XCTest swift_test built under a named flag set.

    Args:
        name: Target name.
        srcs: Swift test sources.
        flag_set: A key of SWIFT_FLAG_SETS.
        copts: Extra compiler flags, after the set's.
        **kwargs: Passed to swift_test (deps, data, tags).
    """
    swift_test(
        name = name,
        srcs = srcs,
        copts = _flags(flag_set, copts),
        **kwargs
    )

def tbhb_swift_sanitizer_test(name, srcs, sanitizer, **kwargs):
    """A swift_test built and run under a sanitizer.

    Args:
        name: Target name.
        srcs: Swift test sources.
        sanitizer: One of SWIFT_SANITIZERS.
        **kwargs: Passed to tbhb_swift_test (deps, flag_set, tags).
    """
    if sanitizer not in SWIFT_SANITIZERS:
        fail("unknown sanitizer {!r}; the sanitizers are {}".format(sanitizer, SWIFT_SANITIZERS))
    tbhb_swift_test(
        name = name,
        srcs = srcs,
        features = kwargs.pop("features", []) + [sanitizer],
        **kwargs
    )

def tbhb_ios_application(
        name,
        srcs,
        bundle_id,
        infoplists,
        deps = [],
        module_name = None,
        families = ["iphone"],
        minimum_os_version = IOS_MINIMUM_OS,
        flag_set = "strict",
        copts = [],
        **kwargs):
    """An ios_application for the simulator, over a swift_library of its sources.

    The library is `<name>_lib`. Nothing is signed: no provisioning profile,
    certificate or team ID. Info.plist needs `CFBundleVersion` and
    `CFBundleShortVersionString`.

    Args:
        name: Target name.
        srcs: Swift sources, the `@main` among them.
        bundle_id: The bundle identifier.
        infoplists: Info.plist files.
        deps: Targets the sources import.
        module_name: The Swift module name; defaults to `name`.
        families: Device families.
        minimum_os_version: The minimum iOS.
        flag_set: A key of SWIFT_FLAG_SETS.
        copts: Extra compiler flags, after the set's.
        **kwargs: Passed to ios_application.
    """
    tbhb_swift_library(
        name = name + "_lib",
        srcs = srcs,
        module_name = module_name or name,
        deps = deps,
        flag_set = flag_set,
        copts = copts,
    )
    ios_application(
        name = name,
        bundle_id = bundle_id,
        families = families,
        infoplists = infoplists,
        minimum_os_version = minimum_os_version,
        deps = [":" + name + "_lib"],
        **kwargs
    )

def tbhb_ios_unit_test(
        name,
        srcs,
        test_host,
        deps = [],
        module_name = None,
        device_type = IOS_SIMULATOR_DEVICE,
        os_version = IOS_SIMULATOR_OS,
        minimum_os_version = IOS_MINIMUM_OS,
        flag_set = "strict",
        copts = [],
        **kwargs):
    """An ios_unit_test that runs on a simulator, hosted by an app.

    Bazel's sandbox needs no extra setting for the simulator. The test's
    library is `<name>_lib` and its runner `<name>_runner`.

    Args:
        name: Target name.
        srcs: XCTest sources.
        test_host: The ios_application that hosts the tests.
        deps: Targets the sources import.
        module_name: The Swift module name; defaults to `name`.
        device_type: The simulator device.
        os_version: The simulator's iOS version, which must be installed.
        minimum_os_version: The minimum iOS.
        flag_set: A key of SWIFT_FLAG_SETS.
        copts: Extra compiler flags, after the set's.
        **kwargs: Passed to ios_unit_test.
    """
    tbhb_swift_library(
        name = name + "_lib",
        testonly = True,
        srcs = srcs,
        module_name = module_name or name,
        deps = deps,
        flag_set = flag_set,
        copts = copts,
    )
    ios_xctestrun_runner(
        name = name + "_runner",
        device_type = device_type,
        os_version = os_version,
    )
    ios_unit_test(
        name = name,
        minimum_os_version = minimum_os_version,
        runner = ":" + name + "_runner",
        test_host = test_host,
        deps = [":" + name + "_lib"],
        **kwargs
    )

def tbhb_macos_application(
        name,
        srcs,
        bundle_id,
        infoplists,
        deps = [],
        module_name = None,
        minimum_os_version = MACOS_MINIMUM_OS,
        flag_set = "strict",
        copts = [],
        **kwargs):
    """An unsigned macos_application, over a swift_library of its sources.

    The library is `<name>_lib`.

    Args:
        name: Target name.
        srcs: Swift sources, the `@main` among them.
        bundle_id: The bundle identifier.
        infoplists: Info.plist files.
        deps: Targets the sources import.
        module_name: The Swift module name; defaults to `name`.
        minimum_os_version: The minimum macOS.
        flag_set: A key of SWIFT_FLAG_SETS.
        copts: Extra compiler flags, after the set's.
        **kwargs: Passed to macos_application.
    """
    tbhb_swift_library(
        name = name + "_lib",
        srcs = srcs,
        module_name = module_name or name,
        deps = deps,
        flag_set = flag_set,
        copts = copts,
    )
    macos_application(
        name = name,
        bundle_id = bundle_id,
        infoplists = infoplists,
        minimum_os_version = minimum_os_version,
        deps = [":" + name + "_lib"],
        **kwargs
    )

def tbhb_macos_unit_test(
        name,
        srcs,
        test_host,
        deps = [],
        module_name = None,
        minimum_os_version = MACOS_MINIMUM_OS,
        flag_set = "strict",
        copts = [],
        **kwargs):
    """A macos_unit_test hosted by an app.

    The test's library is `<name>_lib`.

    Args:
        name: Target name.
        srcs: XCTest sources.
        test_host: The macos_application that hosts the tests.
        deps: Targets the sources import.
        module_name: The Swift module name; defaults to `name`.
        minimum_os_version: The minimum macOS.
        flag_set: A key of SWIFT_FLAG_SETS.
        copts: Extra compiler flags, after the set's.
        **kwargs: Passed to macos_unit_test.
    """
    tbhb_swift_library(
        name = name + "_lib",
        testonly = True,
        srcs = srcs,
        module_name = module_name or name,
        deps = deps,
        flag_set = flag_set,
        copts = copts,
    )
    macos_unit_test(
        name = name,
        minimum_os_version = minimum_os_version,
        test_host = test_host,
        deps = [":" + name + "_lib"],
        **kwargs
    )

def tbhb_swiftlint_test(name, srcs, config = ".swiftlint.yml", **kwargs):
    """Runs SwiftLint over `srcs`, failing on any violation, warnings included.

    The binary is this module's pinned release, fetched by sha256, so it is
    hermetic; it is a macOS executable.

    Args:
        name: Target name.
        srcs: Swift sources to lint.
        config: The SwiftLint config file.
        **kwargs: Passed to sh_test.
    """
    sh_test(
        name = name,
        srcs = [_SWIFTLINT_SCRIPT],
        data = srcs + [config, _SWIFTLINT],
        env = {
            "SWIFTLINT": "$(rootpath {})".format(_SWIFTLINT),
            "SWIFTLINT_CONFIG": "$(rootpath {})".format(config),
            "SWIFTLINT_SOURCES": _rootpaths(srcs),
        },
        **kwargs
    )

def tbhb_swift_format_test(name, srcs, config = ".swift-format", **kwargs):
    """Runs swift-format lint over `srcs`, with Xcode's copy of it.

    swift-format has no release binary and no registry module, so this isn't
    hermetic: it runs the swift-format in the Xcode the host selects, and the
    pinned tools can't vouch for it. The target is always `manual`, so
    `//...` skips it; run it by name on a Mac.

    Args:
        name: Target name.
        srcs: Swift sources to lint.
        config: The `.swift-format` file.
        **kwargs: Passed to sh_test.
    """
    sh_test(
        name = name,
        srcs = [_SWIFT_FORMAT_SCRIPT],
        data = srcs + [config],
        env = {
            "SWIFT_FORMAT_CONFIG": "$(rootpath {})".format(config),
            "SWIFT_FORMAT_SOURCES": _rootpaths(srcs),
        },
        tags = kwargs.pop("tags", []) + ["manual"],
        **kwargs
    )

def tbhb_swift_strict_test(name, srcs, module_name = None, flag_set = "strict", **kwargs):
    """Type-checks `srcs` under a flag set, with the host Xcode's swiftc.

    The check runs at test time, so a source that breaks the set fails this
    test and a failing-first proof can wrap it. A swift_library with the
    same flags would fail the build instead. It needs Xcode, and `srcs`
    must stand alone: they can import only what the SDK has.

    Args:
        name: Target name.
        srcs: Swift sources of one module.
        module_name: The Swift module name; defaults to `name`.
        flag_set: A key of SWIFT_FLAG_SETS.
        **kwargs: Passed to sh_test.
    """
    sh_test(
        name = name,
        srcs = [_SWIFTC_TYPECHECK_SCRIPT],
        data = srcs,
        env = {
            "SWIFTC_FLAGS": " ".join(_flags(flag_set, [])),
            "SWIFTC_MODULE_NAME": module_name or name,
            "SWIFTC_SOURCES": _rootpaths(srcs),
        },
        **kwargs
    )
