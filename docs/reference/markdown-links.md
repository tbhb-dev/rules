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
    at: "2026-11-13T23:34:57Z"
---

# Markdown links

`//repo/tests:markdown_links_test` runs in `//:baseline_tests`, which `//:all` includes. It asks Git for the tracked files and reads every tracked `.md` file. A relative link must name a tracked file or directory. An in-page `#anchor` must match a heading in the same file, using GitHub's anchor rules. A `#fragment` on a link to another file fails, so link to the file only. The check skips external links, anything with a URI scheme such as `https:` or `mailto:`, and anything inside code spans, fenced code blocks, or frontmatter. It never uses the network.

The check prints one `path:line: message` line for each problem. It exits 0 when clean, 1 on problems, and 2 when it could not run, for example on a broken `.markdown-links.toml`.

`.markdown-links.toml` at the repository root lists exclusions as `[[exclude]]` tables. Each has a path `glob`, matched against the file that holds the link, and a nonblank `reason`. An exclusion that matches no failing link fails the check, so the list cannot go stale. There is no baseline file or ratchet. The fixtures under `repo/tests/testdata/markdown_links` cover a clean tree and one bad case each for a missing file, a missing directory, a bad anchor, a rejected fragment, and a stale exclusion.
