---
description: The pnpm settings in each pnpm-workspace.yaml, and why those files have no comments or license header.
status: stable
tags: [pnpm, javascript]
title: pnpm workspace settings
type: Reference
generated:
  - role: generated
    harness: claude-code:2.1.322
    model: anthropic:claude-opus-5-5
    effort: medium
    surface: cli
    session: sha-256-64:debb814921f029ad
    at: "2026-11-11T07:27:14Z"
---

# pnpm workspace settings

Each pnpm workspace in this repository keeps its pnpm settings in a `pnpm-workspace.yaml` beside its `package.json`. pnpm 11 and later no longer read the `pnpm` field of `package.json`, and rules_js reads `pnpm-workspace.yaml` too.

## Settings

- `allowBuilds` is empty in every workspace, because no lifecycle script may run.
- `autoInstallPeers` is off in `storybook` and `tokens`:
  - In `storybook`, the renderer libraries the frameworks peer on (`react` and `react-dom`, `lit`, `astro`) belong to the consumer and load at run time from the consumer's tree. The lock doesn't include a copy of its own that could load beside the consumer's.
  - In `tokens`, `@terrazzo/plugin-css` peers on `@terrazzo/cli` for its config loader. The rules call `@terrazzo/parser`'s JavaScript API instead and don't use the loader, and `@terrazzo/cli` would add native binaries from Vite, `rolldown` and `lightningcss` to the lock.

## Comments and license header

pnpm rewrites `pnpm-workspace.yaml` when it updates a setting, such as an entry under `overrides` that a dependency update moves, and the rewrite drops comments and the YAML document start. The files contain only settings, and this page records what their comments used to say:

- `REUSE.toml` annotates `**/pnpm-workspace.yaml` with the license and copyright, as it does `**/pnpm-lock.yaml`.
- Each `.ryl.toml` that covers a workspace exempts `**/pnpm-workspace.yaml` from the `document-start` rule through `[lint.per-file-ignores]`. Every other `ryl` rule still applies.
