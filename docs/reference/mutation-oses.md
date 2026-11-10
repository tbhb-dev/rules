---
description: Mutation OS selection and checks for platform-specific source code.
status: stable
tags: [bazel, testing]
title: Mutation operating systems
type: Reference
generated:
  - role: generated
    harness: codex
    model: openai:gpt-6.1-sol
    at: "2026-11-10T07:40:00Z"
---

# Mutation operating systems

`gomutants_test` and `mutmut_test` accept `mutation_oses = None`. Leaving it unset or setting it to `None` preserves the target's existing compatibility. For Go, the caller's `target_compatible_with` still applies to each package report and the gate. Python retains its Windows exclusion, on the runner, report, and gate.

A list selects any of `"linux"`, `"macos"`, and `"windows"`. Each name maps to the matching `@platforms//os:<name>` constraint. A `select()` allows any listed OS and yields `@platforms//:incompatible` elsewhere. The macro concatenates this restriction with the caller's `target_compatible_with`. Both must hold. Python also retains its Windows exclusion, so listing Windows can't enable mutmut there. An empty list skips all OSes. Unknown names fail while loading the package.

Only mutation targets receive this restriction. Unit tests and coverage gates remain separate targets with their existing compatibility.

```starlark
gomutants_test(
    name = "mutation_test",
    tests = [":unit_test"],
    go_mod = "go.mod",
    mutation_oses = ["linux", "macos", "windows"],
)
```

## Source check

Load `mutation_oses_test` from `@tbhb_rules//lint:defs.bzl`. Give `srcs` the `BUILD` files and source files to check, such as a `repo_files` target. It uses the rules' pinned Python and checks the supplied copy without consulting Git.

```starlark
mutation_oses_test(
    name = "mutation_oses_test",
    srcs = [":repo_files"],
)
```

The check reads direct `gomutants_test` and `mutmut_test` calls in `BUILD` and `BUILD.bazel`. It accepts a literal list of supported names, `None`, or a top-level constant assigned one of those values. Other explicit expressions fail with a diagnostic. Omitted attributes and `None` pass because they preserve the macro's full existing OS set. A restricted list must include the implied OSes to pass.

For each restricted call, it scans files of the macro's language below the `BUILD` directory, including subdirectories. It also scans directories named by literal repository-local `//package:target` labels in that call's `tests` or `srcs`. The check includes tests in its source tree without resolving target dependencies or expanding source-label variables. It reads literal syntax without running the build language. It skips external repositories. Supply all relevant source files. Calls hidden inside custom wrapper macros and renamed imports are outside its direct-call contract. The check skips fixture trees below a `testdata` directory. Fixture tests use `strip_prefix` to present a fixture as a root tree.

Signals are lexical matches, including comments, string literals, and executable statements. The check recognizes the spellings below. It doesn't resolve import aliases or infer arbitrary program behavior. The pattern table in `lint/private/mutation_oses/check_mutation_oses.py` defines the signals and their implied OS sets.

| Language | Signal | Implied OSes |
| --- | --- | --- |
| Go | `//go:build` or `// +build` naming `linux`, `darwin`, `windows`, or `unix` | The OSes allowed by the expression. `darwin` means macOS and `unix` means Linux and macOS. |
| Go | `_linux.go`, `_darwin.go`, `_windows.go`, `_unix.go` | Linux, macOS, Windows, or Linux and macOS, respectively. The check accepts optional `_<arch>` and `_test` suffixes. |
| Go | `runtime.GOOS` | Linux, macOS, Windows. |
| Go | `filepath.Separator`, `os.PathSeparator` | Linux, macOS, Windows. |
| Go | `os.Chmod`, `os.FileMode`, `Mode().Perm` | Linux, macOS, Windows. |
| Go | `"os/exec"`, `syscall.`, `"os/signal"` | Linux, macOS, Windows. |
| Python | `sys.platform`, `os.name`, `platform.system()` | Linux, macOS, Windows. |
| Python | `os.chmod`, `subprocess`, `signal` | Linux, macOS, Windows. |
| Python | `os.path`, `posixpath`, `ntpath` | Linux, macOS, Windows. |
| Python | `WindowsPath`, `PureWindowsPath` | Windows. |

Go filename constraints and build expressions intersect each file's implied set. Modern `go:build` expressions take precedence over legacy `+build` lines. The check supports Boolean conjunction, disjunction, negation, and parentheses. Legacy spaces mean disjunction. Commas and separate lines mean conjunction. Other build tags may independently be true or false. The check keeps a supported OS when the expression could allow it. It models the three supported OSes. Invalid or unsupported expressions fail the check.

The package's required set is the union across its source files. A restricted list must contain every OS in that set, even when another constraint prevents the target from running there. A missing OS fails with `BUILD.bazel:<line>: mutation_oses missing <names>`, in alphabetical order. Files without signals don't require any OS. Go code restricted to Windows by a filename needs Windows. An unrestricted `runtime.GOOS` reference needs all three. Python's existing Windows exclusion remains in force even when the check requires Windows in a declared list.

Run `bazelisk test //:mutation_oses_test` for this repository's source check. Its production consumers leave `mutation_oses` unset. Passing and failing Go and Python fixture trees live under `lint/tests/mutation_oses/testdata`.
