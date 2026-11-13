---
description: How the Markdown link check resolves relative and in-page links, and how exclusions work.
status: stable
tags: [bazel, testing]
title: Markdown links
type: Reference
generated:
  - role: generated
    harness: claude-code:2.1.318
    model: anthropic:claude-sonnet-5-5
    effort: medium
    surface: sdk-cli
    session: sha-256-64:edada43336016d4f
    at: "2026-11-13T23:40:24Z"
---

# Markdown links

`//repo/tests:markdown_links_test` runs in `//:baseline_tests`, which `//:all` includes. It asks Git for the tracked files and reads every tracked `.md` file. A relative link has to point at a tracked file or directory. An in-page `#anchor` has to match a heading in the same file, using GitHub's anchor rules. A `#fragment` on a link to another file fails, so link to the file only. External links, meaning anything with a URI scheme such as `https:` or `mailto:`, pass unchecked, and so do code spans, fenced code blocks, and frontmatter. Network access stays off.

Output is one `path:line: message` line for each problem. Exit status is 0 when clean and 1 on problems. Status 2 means a broken `.markdown-links.toml` or another failure stopped the run.

The file `.markdown-links.toml` sits at the repository root and lists exclusions as `[[exclude]]` tables. Each has a path `glob`, matched against the file that contains the link, and a `reason` with text in it. The check fails on any exclusion whose glob covers only clean links, which exposes stale entries. Fix or exclude every existing failure, because a baseline file or ratchet would hide them. Fixtures under `repo/tests/testdata/markdown_links` cover a clean tree and one bad case each for a missing file, a missing directory, a bad anchor, a rejected fragment, and a stale exclusion.
