---
description: Swift and Apple build macros, pinned tools, quality checks, and the smoke consumer.
status: stable
tags: [swift, apple, bazel]
title: Swift module reference
type: Reference
generated:
  - role: generated
    harness: codex:0.166.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:fed3160030b8f393
    at: "2026-11-12T15:40:17Z"
---

# Swift module reference

Consumers load `@tbhb_rules_swift//:defs.bzl` for Bazel macros that build Swift libraries, iOS simulator apps, macOS apps, and their unit tests. These macros supply this repository's defaults, SwiftLint, strict compiler flags, and sanitizers.

Builds need a Mac with Xcode. Bazel gets Xcode from the host through `apple_support`, so a consumer's `.bazelrc` names its version with `build --xcode_version=27.2`. A host without that version fails. Apps run unsigned, without a provisioning profile, certificate, or team ID.

The `swift/e2e/smoke` consumer loads the module through `local_path_override`. This standalone Bazel 9 workspace builds and tests a library, an iOS simulator app, and a macOS app under the module's checks. The consumer tests the module's macros rather than building the module's own targets separately. On a Mac with Xcode 27.2, run `bazelisk test //...` from `swift/e2e/smoke`.

## Pins

| Dependency | Version | `bazel_compatibility` |
| --- | --- | --- |
| `apple_support` | 2.12.0 | `>=7.4.0` |
| `rules_swift` | 4.2.2 | `>=8.0.0` |
| `rules_apple` | 5.4.0 | `>=8.0.0` |
| `rules_shell` | 0.6.1 | |
| `rules_python` | 1.7.0 | |
| `bazel_skylib` | 1.9.2 | |
| SwiftLint | 0.65.1 | An `http_archive` of `portable_swiftlint.zip`, outside the module registry. Its Secure Hash Algorithm 256 digest is `c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0`. |

The smoke consumer passed with these pins on Bazel 9.3.2, Xcode 27.2 (build 27B52), and Apple Swift 6.4.2. The module's `.bazelrc` sets `--check_direct_dependencies=error`. This check fails when a declared pin falls below the version the module graph resolves.

## Macros

| Macro | Wraps | Defaults |
| --- | --- | --- |
| `tbhb_swift_library(name, srcs, module_name, flag_set, copts)` | `swift_library` | `module_name` is `name`, `flag_set` is `"strict"` |
| `tbhb_swift_test(name, srcs, flag_set, copts)` | `swift_test` | `flag_set` is `"strict"` |
| `tbhb_ios_application(name, srcs, bundle_id, infoplists, deps, module_name, families, minimum_os_version, flag_set, copts)` | `ios_application` over a `<name>_lib` library | `families` is `["iphone"]`, `minimum_os_version` is `"17.0"` |
| `tbhb_ios_unit_test(name, srcs, test_host, deps, module_name, device_type, os_version, minimum_os_version, flag_set, copts, runner)` | `ios_unit_test` over a `<name>_lib` library and a `<name>_runner` simulator runner | `device_type` is `"iPhone 17"`, `os_version` is `"27.2"` |
| `tbhb_macos_application(name, srcs, bundle_id, infoplists, deps, module_name, minimum_os_version, flag_set, copts)` | `macos_application` over a `<name>_lib` library | `minimum_os_version` is `"14.0"` |
| `tbhb_macos_unit_test(name, srcs, test_host, deps, module_name, minimum_os_version, flag_set, copts)` | `macos_unit_test` over a `<name>_lib` library | `minimum_os_version` is `"14.0"` |
| `tbhb_swiftlint_test(name, srcs, config)` | SwiftLint, `--strict` | `config` is `".swiftlint.yml"` |
| `tbhb_swift_format_test(name, srcs, config)` | `swift-format lint --strict` from Xcode | `config` is `".swift-format"`, always tagged `manual` |
| `tbhb_swift_strict_test(name, srcs, module_name, flag_set)` | `swiftc -typecheck` under the flag set | `flag_set` is `"strict"` |
| `tbhb_swift_sanitizer_test(name, srcs, sanitizer)` | `swift_test` with the sanitizer feature | `sanitizer` is `"asan"` or `"tsan"` |

`tbhb_ios_unit_test` generates a runner with the module's `//private/simulator:create_simulator` action. The action selects an available iOS runtime that supports both `device_type` and `os_version`, including device-specific runtimes. Pass `runner` to use a custom runner. The Python tests for the simulator tools live in `swift/private/simulator`.

App and test macros accept the remaining attributes of the wrapped rule as keyword arguments. Install the simulator's iOS version on the host. An app's `Info.plist` needs `CFBundleVersion` and `CFBundleShortVersionString`.

`SWIFT_FLAG_SETS` in `swift/defs.bzl` names the compiler flag sets. Extra `copts` arguments follow the set's flags. With `"strict"`, the flags are `-warnings-as-errors -strict-concurrency=complete`, while `"default"` is empty. The smoke consumer builds cleanly under `"strict"`.

## Host tools

| Tool | Host dependency |
| --- | --- |
| Every library, app, and test macro | Xcode supplies `swiftc`, software development kits, and simulators |
| `tbhb_swift_format_test` | Xcode supplies `swift-format`. It has no release binary or registry module, so Bazel can't fetch it. The target has the `manual` tag, so `//...` skips it. Run it by name. |
| `tbhb_swift_strict_test` | It runs `xcrun swiftc` at test time |
| `tbhb_swift_sanitizer_test` | Xcode supplies the sanitizer runtimes |

SwiftLint runs from a pinned archive. Bazel fetches the macOS executable and checks its Secure Hash Algorithm 256 digest, without using a copy from `PATH` or Homebrew.

## Quality checks

A check counts as active when CI runs it and a proof expects it to fail on a broken sample. Checks without both remain pending. The proofs are in `swift/e2e/smoke`.

| Check | State | Proof |
| --- | --- | --- |
| SwiftLint `--strict` | Active | `//:proof_swiftlint_fails` expects `Force Cast Violation` from `planted/ForceCast.swift` |
| Strict flag set | Active | `//:proof_strict_fails` expects `var 'counter' is not concurrency-safe` from `planted/GlobalState.swift`. The control, `//:planted_default_test`, passes with the same file under `"default"`. |
| AddressSanitizer | Active | `//:proof_asan_fails` expects `AddressSanitizer: heap-use-after-free` from `planted/UseAfterFree.swift` |
| ThreadSanitizer | Active | `//:proof_tsan_fails` expects `ThreadSanitizer: (data race\|Swift access race)` from `planted/DataRace.swift` |
| `swift-format` | Pending | The target passes on the smoke sources on a Mac, but CI doesn't run it because it uses the copy from Xcode |
| Coverage threshold | Pending | `bazelisk coverage` writes a report with no line or branch records for `swift_test`. See the measurement below. |
| Mutation | Pending | No tool chosen |
| Analyzer | Pending | No Swift analyzer chosen |
| UndefinedBehaviorSanitizer | Pending | No trial recorded |

## Smoke targets and proofs

| Target | Purpose |
| --- | --- |
| `//:Greeting`, `//:Greeting_test` | `tbhb_swift_library` and its `tbhb_swift_test` using `XCTest` |
| `//:ios_app`, `//:ios_app_test` | `tbhb_ios_application` for the simulator and `tbhb_ios_unit_test` on an iPhone 17 simulator with iOS 27.2 |
| `//:macos_app`, `//:macos_app_test` | `tbhb_macos_application` and `tbhb_macos_unit_test` |
| `//:swiftlint_test` | SwiftLint with `--strict` over the library, app, and test sources |
| `//:strict_test` | `tbhb_swift_strict_test` over the `Greeting` sources |
| `//:Greeting_asan_test`, `//:Greeting_tsan_test` | `tbhb_swift_sanitizer_test` under AddressSanitizer and ThreadSanitizer |
| `//:swift_format_test` | `tbhb_swift_format_test` with the copy of `swift-format` from Xcode, tagged `manual` to exclude it from `//...` |

The `planted/` files contain deliberate faults. No library or app target builds them. Each `proof_*` target runs a check over one planted file, and each `proof_*_fails` target uses `expect_failure_test` to require the expected diagnostic. The strict proof's control, `//:planted_default_test`, runs `GlobalState.swift` under the `"default"` flag set and passes.

In the smoke consumer, `.swiftlint.yml` excludes `.bazel-*` to skip the symlinked output trees, and the lockfile stays outside version control.

## Coverage measurement

Both branches of the smoke library's `message` function have tests. From the smoke directory, measure coverage with:

```shell
bazelisk coverage --nocache_test_results --combined_report=lcov //:Greeting_test
```

The target reports `//:Greeting_test PASSED`, but `.bazel-testlogs/Greeting_test/coverage.dat` is empty. The combined report at `.bazel-out/_coverage/_coverage_report.dat` holds only `SF:Sources/Greeting/Greeting.swift` with `FNF:0`, `FNH:0`, `LH:0`, and `LF:0`. It has zero `DA:` and `BRDA:` lines. Adding `--instrumentation_filter=^//`, followed by `--experimental_use_llvm_covmap`, gave the same report. Coverage of `//:macos_app_test` fails to link `macos_app` with `ld: symbol(s) not found for architecture arm64`.

## Compiler flag trials

The smoke library, both apps, and their tests had these results with `bazelisk build`. A flag set through `--@@rules_swift+//swift:copt` also reaches `rules_swift`'s own targets.

| Flag set | Result |
| --- | --- |
| `-warnings-as-errors -strict-concurrency=complete` (`"strict"`) | Builds and tests pass |
| `"strict"` plus `-swift-version 6` | Build passes |
| `"strict"` plus `-enable-upcoming-feature ExistentialAny` | Build passes |
| `"strict"` plus `-enable-upcoming-feature MemberImportVisibility` | Build passes |
| `"strict"` plus `-enable-upcoming-feature NonisolatedNonsendingByDefault` | Build passes |
| `"strict"` plus `-require-explicit-sendable` | Build passes |
| `"strict"` plus `-enable-upcoming-feature InternalImportsByDefault` | Fails in `rules_swift`'s `test_observer` target because the flag also reaches that dependency |

Only the first set belongs to `"strict"`. The other flags have no proof that expects a failure.

## Smoke findings

These observations come from a macOS 27.2 arm64 host with Xcode 27.2 (build 27B52), Apple Swift 6.4.2, and Bazel 9.3.2:

- `rules_apple` 5.4.0 and `rules_swift` 4.2.2 build and test the library and both apps together.
- The default runner selects a compatible runtime, and Bazel's sandbox runs the iOS simulator test with no extra setting. The log says `Created new simulator 'BAZEL_TEST_iPhone 17_27.2'`. The test fails unless `targetEnvironment(simulator)` holds.
- SwiftLint runs from the pinned archive.
- `swift-format` depends on Xcode. It has no release binary, and the registry has no `swift-format`, `swift-markdown`, or `swift-cmark` module.

The first `ios_app_test` run took about 78 seconds, including simulator creation. A later run took about 26 seconds.
