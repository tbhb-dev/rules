<!--
SPDX-License-Identifier: Apache-2.0
Copyright Tony Burns
-->

# tbhb_rules_swift

Bazel macros for Swift and Apple builds in tbhb-dev repositories: a Swift library, an iOS simulator app, a macOS app and their unit tests, with this repository's defaults, SwiftLint, strict compiler flags and sanitizers. Consumers load `@tbhb_rules_swift//:defs.bzl`.

Everything here needs a Mac with Xcode. Xcode is the one toolchain Bazel doesn't bring. It comes from the host through apple_support's Xcode config, so a consumer's `.bazelrc` names the version it builds with (`build --xcode_version=27.2`), and a host without that version fails. Nothing here signs, and nothing needs a provisioning profile, a certificate or a team ID.

`e2e/smoke` is a consumer that loads the module with `local_path_override` and builds and tests one library, one iOS simulator app and one macOS app, under every gate in the table below. Run it from that directory with `bazelisk test //...`.

## Pins

| Dependency | Version | `bazel_compatibility` |
| --- | --- | --- |
| `apple_support` | 2.12.0 | `>=7.4.0` |
| `rules_swift` | 4.2.2 | `>=8.0.0` |
| `rules_apple` | 5.4.0 | `>=8.0.0` |
| `rules_shell` | 0.6.1 | |
| `bazel_skylib` | 1.9.2 | |
| SwiftLint | 0.65.1 | not a module: an `http_archive` of `portable_swiftlint.zip`, sha256 `c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0` |

These are the versions the smoke consumer proved with Bazel 9.3.2, Xcode 27.2 (build 27B52) and Apple Swift 6.4.2. The module's `.bazelrc` sets `--check_direct_dependencies=error`, so a pin below what the module graph resolves fails.

## Macros

| Macro | Wraps | Defaults |
| --- | --- | --- |
| `tbhb_swift_library(name, srcs, module_name, flag_set, copts)` | `swift_library` | `module_name` is `name`, `flag_set` is `"strict"` |
| `tbhb_swift_test(name, srcs, flag_set, copts)` | `swift_test` | `flag_set` is `"strict"` |
| `tbhb_ios_application(name, srcs, bundle_id, infoplists, deps, module_name, families, minimum_os_version, flag_set, copts)` | `ios_application` over a `<name>_lib` library | `families` is `["iphone"]`, `minimum_os_version` is `"17.0"` |
| `tbhb_ios_unit_test(name, srcs, test_host, deps, module_name, device_type, os_version, minimum_os_version, flag_set, copts)` | `ios_unit_test` over a `<name>_lib` library and a `<name>_runner` simulator runner | `device_type` is `"iPhone 17"`, `os_version` is `"27.2"` |
| `tbhb_macos_application(name, srcs, bundle_id, infoplists, deps, module_name, minimum_os_version, flag_set, copts)` | `macos_application` over a `<name>_lib` library | `minimum_os_version` is `"14.0"` |
| `tbhb_macos_unit_test(name, srcs, test_host, deps, module_name, minimum_os_version, flag_set, copts)` | `macos_unit_test` over a `<name>_lib` library | `minimum_os_version` is `"14.0"` |
| `tbhb_swiftlint_test(name, srcs, config)` | SwiftLint, `--strict` | `config` is `".swiftlint.yml"` |
| `tbhb_swift_format_test(name, srcs, config)` | Xcode's `swift-format lint --strict` | `config` is `".swift-format"`, always tagged `manual` |
| `tbhb_swift_strict_test(name, srcs, module_name, flag_set)` | `swiftc -typecheck` under the flag set | `flag_set` is `"strict"` |
| `tbhb_swift_sanitizer_test(name, srcs, sanitizer)` | `swift_test` with the sanitizer's feature | `sanitizer` is `"asan"` or `"tsan"` |

The application and test macros take the remaining attributes of the rule they wrap as keyword arguments. The simulator's iOS version must be installed on the host. The `Info.plist` of an app needs `CFBundleVersion` and `CFBundleShortVersionString`.

`SWIFT_FLAG_SETS` in `defs.bzl` names the compiler flag sets, and `copts` come after the set's flags. `"strict"` is `-warnings-as-errors -strict-concurrency=complete`, and `"default"` is empty. The smoke consumer builds clean under `"strict"`.

## Tools That Need Xcode

| Tool | Why |
| --- | --- |
| Every library, app and test macro | `swiftc`, the SDKs and the simulators come from the Xcode the host selects |
| `tbhb_swift_format_test` | swift-format has no release binary and no registry module, so this runs the copy in Xcode's toolchain. That copy is host state, not something Bazel fetched, and the target is `manual` so `//...` skips it. Run it by name |
| `tbhb_swift_strict_test` | It runs `xcrun swiftc` at test time |
| `tbhb_swift_sanitizer_test` | The sanitizer runtimes come from Xcode |

SwiftLint is hermetic. Bazel fetches its pinned binary, a macOS executable, by sha256, and no PATH or Homebrew copy takes part.

## Strict Gates

A gate is in when it runs in CI and has a failing-first proof: a sample that breaks it, and a test that expects the failure. A gate without both is pending. A separate survey decides which further gates Swift adopts, and each one slots in as its proof lands. Every proof lives in `e2e/smoke`.

| Gate | State | Failing-first proof |
| --- | --- | --- |
| SwiftLint `--strict` | in | `//:proof_swiftlint_fails` expects `Force Cast Violation` from `planted/ForceCast.swift` |
| Strict flag set | in | `//:proof_strict_fails` expects `var 'counter' is not concurrency-safe` from `planted/GlobalState.swift`. `//:planted_default_test` shows the same file passes under the `"default"` set |
| AddressSanitizer | in | `//:proof_asan_fails` expects `AddressSanitizer: heap-use-after-free` from `planted/UseAfterFree.swift` |
| ThreadSanitizer | in | `//:proof_tsan_fails` expects `ThreadSanitizer: data race` from `planted/DataRace.swift` |
| swift-format | pending | The target runs on a Mac and passes on the smoke sources, but it uses Xcode's copy, so CI doesn't run it |
| Coverage threshold | pending | `bazelisk coverage` writes an LCOV file with no line or branch records for `swift_test`, so there is nothing to gate. The measurement is below |
| Mutation | pending | No tool chosen yet |
| Analyzer | pending | No Swift analyzer chosen yet |
| UndefinedBehaviorSanitizer | pending | Not tried |

## Coverage Measurement

On the smoke consumer, with the `Greeting` library's two-branch `message` and a test for each branch:

```text
bazelisk coverage --nocache_test_results --combined_report=lcov //:Greeting_test
```

`//:Greeting_test PASSED`, and `.bazel-testlogs/Greeting_test/coverage.dat` is empty. The combined report, `.bazel-out/_coverage/_coverage_report.dat`, holds only `SF:Sources/Greeting/Greeting.swift` with `FNF:0`, `FNH:0`, `LH:0` and `LF:0`. It has 0 `DA:` lines and 0 `BRDA:` lines. Adding `--instrumentation_filter=^//`, and then `--experimental_use_llvm_covmap`, gave the same report. Coverage of `//:macos_app_test` fails to link `macos_app` with `ld: symbol(s) not found for architecture arm64`.

## Flag Sets Tried

On the smoke consumer, built with `bazelisk build` on the library, both apps and their tests. A flag added with `--@@rules_swift+//swift:copt` also reaches rules_swift's own targets.

| Flag set | Result |
| --- | --- |
| `-warnings-as-errors -strict-concurrency=complete` (`"strict"`) | builds and tests clean |
| `"strict"` plus `-swift-version 6` | builds clean |
| `"strict"` plus `-enable-upcoming-feature ExistentialAny` | builds clean |
| `"strict"` plus `-enable-upcoming-feature MemberImportVisibility` | builds clean |
| `"strict"` plus `-enable-upcoming-feature NonisolatedNonsendingByDefault` | builds clean |
| `"strict"` plus `-require-explicit-sendable` | builds clean |
| `"strict"` plus `-enable-upcoming-feature InternalImportsByDefault` | fails in rules_swift's own `test_observer` target, which the flag also reaches. The smoke sources weren't the cause |

Only the first set is in the `"strict"` list. The others aren't gates, because no failing-first proof covers them.

## Findings From The Smoke Consumer

| Question | Outcome |
| --- | --- |
| Do rules_apple 5.4.0 and rules_swift 4.2.2 work with Xcode 27.2 and Swift 6.4? | Yes: the library, the iOS simulator app and the macOS app build and test |
| Does Bazel's sandbox let an iOS simulator test run? | Yes, with no extra setting. The test log says `Created new simulator 'BAZEL_TEST_iPhone 17_27.2'`, and the test fails unless `targetEnvironment(simulator)` holds |
| Does SwiftLint run hermetically? | Yes, from the pinned archive |
| Does swift-format run hermetically? | No: it has no release binary, and the registry has no `swift-format`, `swift-markdown` or `swift-cmark` module |

The `ios_app_test` run took about 78 seconds the first time, which includes creating the simulator, and about 26 seconds when rerun.
