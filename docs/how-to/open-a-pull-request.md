---
description: Draft a pull request description, check it with the interim script, then open or update the pull request.
generated:
  - role: generated
    harness: claude-code
    model: anthropic:claude-sonnet-5-5
    at: "2026-11-03T02:00:00Z"
  - role: generated
    harness: claude-code:2.1.316
    model: anthropic:claude-opus-5-5
    effort: medium
    surface: cli
    session: sha-256-64:debb814921f029ad
    subagent: sha-256-64:3e4e1178daf8cb39
    at: "2026-11-03T04:31:04Z"
  - role: generated
    harness: claude-code:2.1.316
    model: anthropic:claude-opus-5-5
    effort: medium
    surface: cli
    session: sha-256-64:debb814921f029ad
    at: "2026-11-03T05:02:02Z"
status: draft
tags: [pull-request, tooling]
title: Open a pull request
type: How-to
---

# Open a pull request

The interim script `tools/interim/pull_request.py` checks a pull request draft and runs `gh` to open or update the pull request from it. A real tool replaces it later. The script never commits, pushes, or creates a branch. The branch must already be on the remote.

## Write the draft

Write the draft to `.github/PULL_REQUEST_DRAFT.md`, which git ignores, starting from `.github/PULL_REQUEST_TEMPLATE.md`. It has three parts.

- Optional YAML frontmatter with the pull request metadata. [pull-request-draft.schema.json](https://github.com/tbhb-dev/ascm/blob/main/.github/schemas/pull-request-draft.schema.json) lists the fields and rejects any other: `base`, `draft`, `labels`, `reviewers`, `assignees`, and `milestone`. The base defaults to `main`, and `draft` defaults to false.
- One H1 as the first line after the frontmatter. That line becomes the pull request title, a Conventional Commit header of at most 72 characters.
- The sections from the template, in the template order. The script requires `Why`, `Behavior change`, and `Verification`. Leave out an optional section rather than leaving it empty.

Write each paragraph and list item on one line. GitHub renders a newline in a description as a line break, so a paragraph wrapped at 72 columns shows as ragged short lines. The check reports a wrapped paragraph and the line it starts on. Code blocks, tables, and headings are exempt, and each list item stays on its own line. The squash merge wraps the commit message at 72 columns, so the draft doesn't need to.

Each section has a word limit. `.github/pull-request-sections.toml` holds those limits along with the required sections, and the template comments repeat the numbers. Fenced code, inline code, link URLs, and HTML comments don't count. Remove every template comment and placeholder before you check.

Never write `Generated-by`, `Assisted-by`, `Signed-off-by`, or `Co-authored-by` lines. The script adds the first two and rejects a draft with any of the four.

## Check the draft

```console
mise run pr -- check
```

Pass a path to check another file. Without one, the script reads the draft file. Each problem prints as a `path:line: problem` line. Any problem at all makes the exit code 1.

Checks cover the frontmatter, the title, the sections with their limits, and the rendered description. A tool named `cog` (`cocogitto` in the mise settings) verifies the title as a Conventional Commit header. The script lints the description with `vale`, `cspell`, and `rumdl` under the repository configuration, then maps each finding back to its line in the draft. If a tool is missing, the script stops and names it.

## Let the hook check the draft

Each harness runs `pull_request.py hook` with its own name after every write. That gives the draft the same checks without a manual step. Claude Code wires it in `.claude/settings.json`, Antigravity in `.agents/hooks.json`, and Codex in `.codex/hooks.json`.

On each call, the hook reads the tool call from standard input and ignores any call that didn't write the draft. If the draft has problems, the hook exits 2 and prints them to standard error, where the agent reads them and fixes the file. A clean draft produces nothing to read. Trailer checks belong to `create` and `edit` only. If the hook crashes or a tool is missing, it prints a warning and exits 0, so a broken hook never blocks an agent.

## Open the pull request

```console
mise run pr -- create --dry-run
mise run pr -- create
```

`create` runs the checks, then `gh pr create` with the title, the base, and the metadata from the frontmatter. `--dry-run` prints the `gh` command and the description it would send, and runs nothing. The description reaches `gh` on standard input. Because `gh` has no terminal, it can't prompt. If the branch isn't on the remote, `gh` fails, and the script prints that error unchanged.

To update a pull request that exists, run `mise run pr -- edit --pr 12`. It calls `gh pr edit` with the title and description from the draft, and adds the draft's labels.

## Trailers

Both `create` and `edit` append the agent trailers as the last paragraph of the description. A squash merge copies them into the commit message.

The block lists the `Generated-by` and `Assisted-by` trailers from the commits between the base and `HEAD`, once for each agent identity. Where one identity has both roles, `Generated-by` wins. If an agent runs the script, its own identity joins as `Assisted-by` unless the list already has it, while a person outside an agent gets only the trailers from the commits.

`git interpret-trailers --parse` reads the block, because it uses the commit trailer grammar. The commit range starts at `origin/<base>` when that ref exists, and at the local `<base>` otherwise.
