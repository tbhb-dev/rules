---
okf_version: "0.2"
---

# The `tbhb_rules` docs

Hand-written documentation for tbhb_rules, as an OKF v0.2 bundle. The rules for adding to it are in `AGENTS.md` in this directory.

## Reference

* [Commit identity](reference/commit-identity.md) - Allowed identities and required agent identity trailers.
* [Decision records](reference/decision-records.md) - Where decision records live, their names and frontmatter, and what the check enforces.
* [Frontmatter reference](reference/frontmatter.md) - The frontmatter fields, their values, and how they map to commit trailers.
* [Markdown links](reference/markdown-links.md) - How the check resolves relative and in-page links in tracked Markdown files.
* [The mise.toml keys](reference/mise-keys.md) - How the check compares the key names of mise.toml with the baseline.
* [Mutation operating systems](reference/mutation-oses.md) - Mutation OS selection and checks for platform-specific source code.
* [pnpm workspace settings](reference/pnpm-workspaces.md) - The pnpm settings each pnpm-workspace.yaml holds, and why those files have no comments or license header.
* [Required files](reference/required-files.md) - How the check finds files that a consumer repository lacks.
* [Review severity and finding ids](reference/review-severity.md) - Severity ratings, evidence requirements, and finding ids for review reports.
* [Swift module reference](reference/swift.md) - Swift and Apple build macros, pinned tools, quality checks, and the smoke consumer.
* [Temporary files](reference/temporary-files.md) - Temporary file paths and the shell source check.
* [Workflow lint](reference/workflow-lint.md) - What the workflow lint check rejects in workflow and action YAML, and what it skips.

## Architecture content rules

* [Arc42 section template](content/arc42-section-template.md) - Required structure for an arc42 section page.
* [Arc42 section writing](content/arc42-section-writing.md) - Rules for writing an arc42 section page.
* [Arc42 section review](content/arc42-section-review.md) - Rules for reviewing an arc42 section page.
* [Structurizr workspace template](content/structurizr-workspace-template.md) - Required structure for a Structurizr workspace source.
* [Structurizr workspace writing](content/structurizr-workspace-writing.md) - Rules for writing and updating a Structurizr workspace.
* [Structurizr workspace review](content/structurizr-workspace-review.md) - Rules for reviewing a Structurizr workspace and its exports.
* [Structurizr macro reference](reference/structurizr.md) - Workspace lint, exports, update targets, and pinned rendering tools.
