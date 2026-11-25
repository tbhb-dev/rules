---
description: How to add a shared ast-grep rule set.
status: stable
tags: [bazel, lint]
title: Shared ast-grep rule sets
type: Reference
generated:
  - role: generated
    harness: codex:0.171.0
    model: openai:gpt-6.2-sol
    effort: high
    surface: exec
    session: sha-256-64:0cfbdf41150e3aef
    at: "2026-11-25T14:46:03Z"
---

<!--
SPDX-License-Identifier: Apache-2.0
Copyright Tony Burns
-->

# Shared ast-grep rule sets

Add a subdirectory with an `sgconfig.yml` and the rule YAML files it references. Export those files as a public `filegroup` in the parent `BUILD.bazel` so consumers can pass the label in `rule_dirs`. Add passing and failing fixtures under `testdata` and exercise them through the [ast-grep lint target](../../../docs/reference/ast-grep.md).

The `example` rule flags the artificial `ast_grep_example_placeholder()` call and serves as a fixture for the Bazel tests.
