---
description: Squash-merge a pull request with a plain-text commit message built from its description, using the interim script.
generated:
  - role: generated
    harness: claude-code
    model: anthropic:claude-sonnet-5-5
    at: "2026-11-03T03:00:00Z"
  - role: generated
    harness: claude-code:2.1.316
    model: anthropic:claude-opus-5-5
    effort: medium
    surface: cli
    session: sha-256-64:debb814921f029ad
    at: "2026-11-03T04:41:52Z"
status: draft
tags: [pull-request, tooling]
title: Merge a pull request
type: How-to
---

# Merge a pull request

GitHub's default squash message pastes the pull request description into the commit as written, Markdown included. The interim script `tools/interim/squash_merge.py` builds a plain-text message from the pull request instead and merges with it. A real tool replaces the script later.

Agents may not merge. Only a person runs the script without `--dry-run`.

## Preview the message

Run the preview from the repository root. It merges nothing and prints the `gh` command, a blank line, then the exact commit message.

```console
mise run merge -- 12 --dry-run
```

An agent can run this command and hand the output to the person who merges.

## Merge

```console
mise run merge -- 12
```

The script reads the title, description, head commit, and merge state through `gh pr view`. It stops with a one-line reason for a draft, a closed pull request, or a conflict, and for any blocked, behind, or dirty merge state that `gh` reports. Failing checks appear in the reason. Branch protection stays with GitHub.

The merge passes `--match-head-commit`, so a push made after the preview makes `gh` refuse the merge.

## Read the message

The subject is the pull request title plus the number, such as `(#12)`. The result must pass `cog verify` and fit 72 characters, or the script stops.

The body comes from the description.

- The script drops HTML comments and empty sections.
- Each `##` heading becomes a plain line with its text directly beneath. A blank line separates blocks, which keeps the sections apart in `git log`.
- Prose wraps at 72 columns. A list item keeps its marker and gets a hanging indent.
- A fenced code block loses its fences and gains a four-space indent. The script leaves its lines unwrapped.
- Inline code stays as written. Emphasis markers go.
- A link keeps its text and gains a numbered marker. The URLs follow the last section as a reference list, since a commit message can't hold a link and the URL points at the issue or spec.

A word, an inline code span, or a URL always stays on one line.

## Trailers

The final Generated-by and Assisted-by paragraph of the description becomes the commit's trailer block. The script copies it as written, never wraps it, and keeps it as the last paragraph. Then `git interpret-trailers --parse` must read the same block back.

The script never adds Co-authored-by. A description with a Signed-off-by or Co-authored-by line gets refused.

A person may pass `--signoff` to append `Signed-off-by:` after the LLM trailers, with the name and email from `git config`. An agent environment gets a refusal for `--signoff`.
