---
description: Blocking and advisory mutation gates, and the pull request switch.
status: stable
tags: [bazel, testing]
title: Mutation gates
type: Reference
generated:
  - role: generated
    harness: codex:0.166.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:d6da80f738f784a1
    at: "2026-11-15T14:02:02Z"
---

# Mutation gates

`mutmut_test` and `gomutants_test` pass their reports to `mutation_gate_test`. The gate blocks survivors by default. Diff selection and `require_scope = "full"` control report scope separately from advisory mode.

## Consumer knobs

Set the macro argument `advisory = True` on `mutmut_test`, `gomutants_test`, or `mutation_gate_test` for a per-target flip. This also permits survivors in full runs of that target. Set `advisory = False` to keep a target blocking even when the command enables advisory mode.

Leave `advisory` unset (or `None`) to follow the shared boolean flag. Pass `--@tbhb_rules//quality:advisory` only in a pull request job. This repository's root workspace also accepts `--//quality:advisory`. Omit the flag or pass `--@tbhb_rules//quality:advisory=false` for blocking push, manual full-scope, and nightly runs. An explicit macro argument takes precedence over the flag.

Advisory mode permits `lived` and `not_covered` survivors, so reviewers answer survivors in review. The gate prints `mutation_gate: advisory, N survivors (not failing)` to stdout and, when writable, `GITHUB_STEP_SUMMARY`.

Errored mutants still fail in advisory mode, along with interrupted runs, invalid accounting, unchecked mutants, excessive timeouts, timeouts without any kills, all-skipped reports, empty full-scope runs, and scope mismatches.

## Repository CI

CI has no nightly mutation job or manual full-scope workflow trigger. Its `ci.yml` matrix enables the flag for `pull_request` events. Pushes to main test every workspace with blocking full reports. For manual verification, run `bazelisk test //...` in each workspace with the default flag and change set settings. Future nightly jobs must keep advisory mode off.
