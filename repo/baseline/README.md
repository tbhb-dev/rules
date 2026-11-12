---
type: Readme
title: Repository baseline
description: Shared files and bootstrap seeds for consumer repositories.
tags: [repository, baseline]
status: stable
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:8f49f11fc6113551
    at: "2026-11-12T01:49:56Z"
---

# Repository baseline

Read any file at any commit with `git show <sha>:repo/baseline/<path>`. The baseline stores plain files that you can read without Bazel. The manifest and both schemas use `schema_version = 1` and JSON Schema 2020-12.

`manifest.toml` maps each repository path to a source relative to this directory. It also records the mode and visibility. An omitted `kinds` applies to every declared kind. An omitted visibility means `all`. Each path has at most one source for each visibility and kind, including the overlap between `all` and a specific visibility.

The directories group sources by purpose:

- `files/` holds shared files.
- `kinds/<kind>/` stores variants for each kind.
- `visibility/public/` and `visibility/private/` hold license variants.
- `seed/<kind>/` holds starting files for bootstrap.

Source names keep tools from treating the baseline as live configuration. They drop the leading dot or add `.baseline` to names that tools would still discover. The manifest keeps the consumer filename in `path` and the stored filename in `source`.

The modes define what a writer or a future check does:

- `bytes` compares the whole file with its source.
- `keys` compares only the listed dotted paths in TOML, YAML, or JSON. Each key must exist in the source. Other keys belong to the repository.
- `lines` requires every non-blank, non-comment source line, in any order. The repository may add lines.
- `seed` writes a file only when absent at bootstrap. Sync never overwrites it, and no check compares it. The CI workflow's structure has a separate check.

A writer substitutes `{{name}}` in files marked `template = true`. Names must appear in `placeholders`. The writer supplies `repo_name`, `rules_sha`, `renovate_config_sha`, `kind`, and `private`. GitHub's `${{ expression }}` syntax belongs to Actions and passes through unchanged. The rules and Renovate pins use `rules_sha` and `renovate_config_sha`. Repository names use `repo_name`. The declaration seed also uses `kind` and the unquoted boolean `private`. JSON values need JSON escaping.

The six `mcp_*` placeholders supply Model Context Protocol (MCP) values: a server name, Go module, endpoint, token path, and environment variable names. They come from writer flags at bootstrap and from the target repository's existing values on sync. The manifest never stores these values. A missing value at bootstrap fails.

`never_write` protects repository-owned paths. Its patterns follow gitignore matching, anchored at the repository root: `*` and `?` don't cross `/`, `**` does, and a pattern without glob characters is an exact path. Writers must leave those paths alone. Dictionaries, Vale vocabularies, dependency manifests, lockfiles, agent instructions, and app import contracts belong to each repository. A repository can extend shared configuration through the `keys` and `lines` modes.

The kinds are `go`, `python`, `docs`, and `chezmoi`. Each `kind` table lists required paths and hook IDs by stage. An empty stage has no required hooks. Visibility requirements extend the kind's requirements. Private repositories also require the `size-check` hook. `visibility/private/pre-commit-config.yaml` holds its definition as a fragment appended to the seeded hook configuration only at bootstrap. This fragment has no separate destination entry. Existing kind requirements can already include that hook. Sync never edits an existing repository's hook configuration. A later check compares hook IDs by stage and reports what's missing.

A `chezmoi` repository stores its source, including `.tmpl` files, under `home/`. Its seeds follow the docs kind. The Bazel file selection and linter exclusions omit `home/`, so generic linters never read those templates. Hook stages follow the docs source, including its empty `pre-push` stage.

A consumer declares its kind and visibility in `.tbhb-repo.toml`:

```toml
schema_version = 1
kind = "go"
private = false

[[exception]]
check = "C2"
path = ".bazelversion"
reason = "A version upgrade needs a separate migration."
```

Unknown schema versions, unknown kinds, and blank exception reasons fail validation. Each exception must still describe a difference. An exception whose file no longer differs fails. Public repositories have an Apache-2.0 `LICENSE`. Private repositories have `LICENSES/LicenseRef-Proprietary.txt` and no Apache `LICENSE`. Future consumer checks cross-check those files against `private`.

Bootstrap seeds start with a small Bazel workspace and a secrets check. They call the shared repository workflow and give branch protection one `conclusion` job that needs every other job. Application-specific build targets and dependency checks come next as the repository adds code. The first build creates the repository-owned module lock.

Renovate ignores `repo/baseline/**`, so it never bumps the baseline copies. Renovate bumps the source repositories' own pins. The baseline follows them only through a reviewed sync pull request that recopies files from a newer source commit. No automation does that resync yet.

`//repo/baseline:manifest_test` validates this manifest, its source files, keys, kinds, placeholders, and destination uniqueness. It also tests invalid manifests and both schemas. Consumer checks C1 to C5, C7, and C8 belong to later changes.
