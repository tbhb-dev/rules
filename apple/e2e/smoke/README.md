<!--
SPDX-License-Identifier: Apache-2.0
Copyright Tony Burns
-->

# Swift and Apple smoke consumer

A standalone Bazel 9 workspace that builds Swift and Apple targets with rules_swift and rules_apple, to answer four questions before the repository takes on Apple rules. It uses no signing, provisioning or certificates: only the iOS simulator and unsigned macOS builds.

Run it from this directory on a Mac with Xcode 27.2: `bazelisk build //...` and `bazelisk test //...`. Xcode is the one toolchain Bazel doesn't bring. It comes from the host through apple_support's Xcode config, and `.bazelrc` names `--xcode_version=27.2`, so a host without it fails.

## Pins

| Module | Version | `bazel_compatibility` |
| --- | --- | --- |
| `apple_support` | 2.12.0 | `>=7.4.0` |
| `rules_swift` | 4.2.2 | `>=8.0.0` |
| `rules_apple` | 5.4.0 | `>=8.0.0` |
| SwiftLint binary | 0.65.1 | not a module: `http_archive` of `portable_swiftlint.zip` |

Each is the latest release on the Bazel Central Registry when this was written. The lockfile isn't committed.

## Targets

| Target | What it is |
| --- | --- |
| `//:Greeting`, `//:Greeting_test` | `swift_library` and its XCTest `swift_test` |
| `//:ios_app`, `//:ios_app_test` | `ios_application` for the simulator, and `ios_unit_test` on an iPhone 17 simulator with iOS 27.2 |
| `//:macos_app`, `//:macos_app_test` | `macos_application` and `macos_unit_test` |
| `//:swiftlint_test` | SwiftLint over every Swift file, `--strict` |
| `//:swift_format_test` | fails on purpose, see below; tagged `manual`, so `//...` skips it |

## Findings

Recorded on a macOS 27.2 arm64 host with Xcode 27.2 (build 27B52) and Apple Swift 6.4.2, Bazel 9.3.2.

| Question | Outcome | Command and output |
| --- | --- | --- |
| Do rules_apple 5.4.0 and rules_swift 4.2.2 work with Xcode 27.2 and Swift 6.4? | passed | `bazelisk build //...`: `INFO: Build completed successfully, 243 total actions` |
| Does Bazel's sandbox let an iOS simulator test run? | passed, with no extra setting | `bazelisk test //...`: `//:ios_app_test PASSED`. The test log says `Created new simulator 'BAZEL_TEST_iPhone 17_27.2'`, and the test fails unless `targetEnvironment(simulator)` holds |
| Does SwiftLint run hermetically? | passed | `bazelisk test //:swiftlint_test`: `Done linting! Found 0 violations, 0 serious in 6 files.` The binary is the pinned archive. A planted `as!` failed the target: `Force Cast Violation: Force casts should be avoided (force_cast)` |
| Does swift-format run hermetically? | failed: no hermetic source | `bazelisk test //:swift_format_test`: `//:swift_format_test FAILED`, with the reason in the log |

The `ios_app_test` run took about 78 seconds the first time, which includes creating the simulator, and 26 seconds when rerun.

### swift-format

swift-format publishes no release binaries. The registry has no `swift-format` module, and no `swift-markdown` or `swift-cmark` module, which a source build needs. The copy in Xcode's toolchain (6.4.4 here) works, and the sources pass `swift-format lint --strict` with `.swift-format`, but that binary is host state, not something Bazel fetched. `//:swift_format_test` therefore fails with that explanation rather than passing without checking anything. It becomes a real check once a pinned binary or a source build exists.

### rules_apple settings

The default sandbox needed no rules_apple setting for the simulator test. Two Info.plist keys are required that a quick build wouldn't expect: `CFBundleVersion` and `CFBundleShortVersionString`.
