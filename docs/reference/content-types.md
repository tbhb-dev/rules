---
type: Reference
title: Content types
description: Reusable design templates, checks, and directory indexes for consuming repositories.
tags: [content, design, bazel]
status: stable
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:fb2bbc10b42a2d56
    at: "2026-11-11T19:02:26Z"
---

# Content types

The `content/` directory holds reusable document skeletons and checklists. Its first type is a design: a directory with a `README.md` and optional topic appendices. Copy [the design template](../../content/design/TEMPLATE.md), complete [the writing checklist](../../content/design/WRITING.md), and use [the review checklist](../../content/design/REVIEW.md) for independent review.

## Check designs

Load `design_test` alongside `vale_test` from `@tbhb_rules//lint:defs.bzl`:

```starlark
load("@tbhb_rules//lint:defs.bzl", "design_test")

design_test(
    name = "design_test",
    srcs = glob(["designs/*/*.md"]),
    forbidden_terms = ["example-session"],
)
```

Supply complete directories.

Include each design's README and appendices. The checker finds directories containing a README or design frontmatter and treats Markdown files beside that README as appendices. Include assets and other relative link destinations in `srcs` or `data`. As with other tree checks, `glob()` stops at Bazel package boundaries. Use `filegroup` or `repo_files` contributions when designs span packages.

Failures print `path:line: problem`. The check enforces:

- README frontmatter type `Design Draft`, nonempty title, description and owner, tags, a valid updated date, and a nonnegative integer `decisions_open`. Status is `draft`, `decided` or `superseded`.
- A status table before Summary, followed by Decisions for tbhb, Already decided, Proposal, How it works, Risks and unknowns, Plan and, if appendices exist, Appendices.
- A Summary of at most 150 words and at most 250 lines in README.md. Set `max_lines` to another limit, or `0` to turn off the line limit.
- A `decisions_open` count matching `### D<n>.` headings within Decisions for tbhb. “None.” with no D headings counts as zero. Each D item has nonempty Recommendation, Why, If yes, If no and Reversible bullets with plain or bold labels.
- Appendix names matching `[A-Z]-<kebab>.md`, type `Design Appendix`, `parent: README.md`, a link back to README, and a README link to every appendix.
- Existing destinations for relative Markdown links, images and reference-link definitions, including hash-prefixed heading anchors in Markdown destinations. The checker skips remote destinations.
- Evidence cells starting with proven, existing, new or unverified in the Risks table, regardless of case.

`forbidden_terms` defaults to an empty list. The rule doesn't include session names. Each caller supplies its own list of literal terms, matched as whole words without regard to case outside inline and fenced code. The same setting is available on the index targets. Mechanical checks supplement the independent substance and privacy review in the checklists.

Template files use the current shared frontmatter schema and its existing types. When copying the template, add the complete design frontmatter shown in its instructions. Design checks use the rules module's pinned Python and PyYAML to check the extra fields. Consumers' general documentation schemas must separately accept those fields and `Design Appendix`.

## Generate a directory index

For `designs/<slug>/README.md`, wire the generator and its matching test over all files:

```starlark
load("@tbhb_rules//lint:defs.bzl", "designs_index", "designs_index_test")

DESIGNS = glob(["designs/**"])

designs_index(
    name = "designs_index",
    srcs = DESIGNS,
)

designs_index_test(
    name = "designs_index_test",
    srcs = DESIGNS,
)
```

Run `bazel run //:designs_index` to write `designs/README.md`.

Commit the result. Run `bazel test //:designs_index_test` to reject a missing or stale index, an invalid slug, a missing README, nested designs, or any subdirectory inside a design. A repository can use this one test target because it also checks each design.

Both targets accept `out` (default `designs/README.md`), `forbidden_terms` and `max_lines`. The directory containing `out` is the designs root. Generator paths are workspace relative even when its `BUILD.bazel` file is in a subpackage. A test's `strip_prefix` changes its copied tree root.

### Index format

The generator reads only the declared source files and writes the validated index in the invoking workspace. It lists title, status, owner, `decisions_open`, and updated in slug order. Each title links to the design's README. Rendering uses UTF-8 and LF newlines and produces identical bytes on repeated runs. Invalid designs prevent writing.

Fixed **`Readme` frontmatter** in the index uses stable status and a design tag, compatible with the current `okf_docs_test` schema. If the directory is inside an OKF docs bundle, list the generated README in that bundle's index. Design documents need frontmatter compatible with the consuming repository's schema.
