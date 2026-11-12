<!--
SPDX-License-Identifier: Apache-2.0
Copyright Tony Burns
-->

# Swift Smoke Consumer

A standalone Bazel 9 workspace that loads `tbhb_rules_swift` through `local_path_override` and builds and tests one library, one iOS simulator app and one macOS app under every gate the module has. The module's own targets aren't built on their own, so this consumer is the test of the module. It uses no signing, provisioning or certificates.

Run it from this directory on a Mac with Xcode 27.2: `bazelisk test //...`. The module's pins, macros and gates are in [`swift/README.md`](../../README.md).

## Targets

| Target | What it is |
| --- | --- |
| `//:Greeting`, `//:Greeting_test` | `tbhb_swift_library` and its XCTest `tbhb_swift_test` |
| `//:ios_app`, `//:ios_app_test` | `tbhb_ios_application` for the simulator, and `tbhb_ios_unit_test` on an iPhone 17 simulator with iOS 27.2 |
| `//:macos_app`, `//:macos_app_test` | `tbhb_macos_application` and `tbhb_macos_unit_test` |
| `//:swiftlint_test` | SwiftLint over the library, app and test sources, `--strict` |
| `//:strict_test` | `tbhb_swift_strict_test` over the `Greeting` sources |
| `//:Greeting_asan_test`, `//:Greeting_tsan_test` | `tbhb_swift_sanitizer_test` under AddressSanitizer and ThreadSanitizer |
| `//:swift_format_test` | `tbhb_swift_format_test` with Xcode's copy of swift-format. Tagged `manual`, so `//...` skips it |

## Failing-First Proofs

The files in `planted/` are broken on purpose, and no library or app target builds them. Each `proof_*` target runs a gate over one planted file, and each `proof_*_fails` target is an `expect_failure_test` that passes only when the proof fails with the expected diagnostic.

| Planted file | Gate | Expected diagnostic |
| --- | --- | --- |
| `ForceCast.swift` | SwiftLint | `Force Cast Violation` |
| `GlobalState.swift` | Strict flag set | `var 'counter' is not concurrency-safe` |
| `UseAfterFree.swift` | AddressSanitizer | `AddressSanitizer: heap-use-after-free` |
| `DataRace.swift` | ThreadSanitizer | `ThreadSanitizer: data race` |

`//:planted_default_test` is the control for the strict proof: it runs `GlobalState.swift` under the `"default"` flag set, and it passes.

## Notes

Recorded on a macOS 27.2 arm64 host with Xcode 27.2 (build 27B52), Apple Swift 6.4.2 and Bazel 9.3.2.

- The simulator test needs no sandbox setting. Its log says `Created new simulator 'BAZEL_TEST_iPhone 17_27.2'`, and it fails unless `targetEnvironment(simulator)` holds.
- An iOS or macOS app's `Info.plist` needs `CFBundleVersion` and `CFBundleShortVersionString`.
- `.swiftlint.yml` excludes `.bazel-*` so SwiftLint skips the symlinked output trees.
- The lockfile isn't committed.
