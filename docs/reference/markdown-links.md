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
    session: sha-256-64:e99c9bcdb2c83649
    at: "2026-11-14T01:03:51Z"
---

# Markdown links

`//repo/tests:markdown_links_test` runs in `//:baseline_tests`, which `//:all` includes. It asks Git for the tracked files and reads every tracked `.md` file. A relative link has to point at a tracked file or directory. The check drops a `?query` from the destination before the lookup. It splits the destination at the first `#` and the first `?` before it decodes percent escapes, so `%23` and `%3F` in a name remain part of the name. A `#fragment` on a link to another file fails, so link to the file only. External links pass unchecked: a destination that starts with `scheme://` or `//`, or with `mailto:` or `tel:`. Any other colon belongs to a relative path, so the check looks up `C:foo` and `notes:2026.md` as files. The check ignores code spans, fenced code blocks, indented code blocks, and frontmatter. An indented block starts after a blank line outside a list item, and ends at the next line with fewer than four spaces of indent. Network access stays off.

## Anchors

An in-page `#anchor` has to match a heading in the same file. The check builds each anchor from the heading text the way GitHub does:

1. Take the text of a hash-prefixed heading (`# Title`, with closing `#` marks dropped) or of a heading underlined with `===` or `---`.
2. Replace each inline link or image with its link text, and delete backticks, `*` and `~`. Underscores remain.
3. Trim, lowercase, delete every character that isn't a word character (a letter or digit of any script, or `_`), a hyphen or a space, then turn each space into a hyphen.
4. Number a repeated anchor `-1`, `-2` and so on, in order, so the second `# Setup` becomes `setup-1`.

The check decodes percent escapes in the fragment and compares it in lowercase, so `#SETUP` matches `# Setup`. An empty fragment (`#`) passes. Headings in frontmatter, fenced code blocks and indented code blocks don't count. Anchors from raw HTML, such as `<a id="x">`, don't count either, so a link to one fails.

Output is one `path:line: message` line for each problem. Exit status is 0 when clean and 1 on problems. Status 2 means a broken `.markdown-links.toml` or another failure stopped the run.

The file `.markdown-links.toml` sits at the repository root and lists exclusions as `[[exclude]]` tables. Each has a path `glob`, matched against the file that contains the link, and a `reason` with text in it. The check fails on any exclusion whose glob covers only clean links, which exposes stale entries. Fix or exclude every existing failure, because a baseline file or ratchet would hide them. Fixtures under `repo/tests/testdata/markdown_links` cover a clean tree and one bad case each for a missing file, a missing directory, a bad anchor, a rejected fragment, a scheme-like path, and a stale exclusion.

## Accepted limits

The scanner matches regular expressions and doesn't parse Markdown. It doesn't handle multi-line reference definitions, deep nesting (a link inside many layers of quotes or lists), escaped parentheses in a destination, or title text that looks like a link. Exclusion globs have no cap: a broad glob hides every failing link under it, so review each glob when you add it.
