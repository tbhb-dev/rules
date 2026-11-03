# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`okf_docs_test`: the docs bundle and every Markdown file's frontmatter."""

load("//runtime:defs.bzl", "python_tool")
load(":tree_check.bzl", "tree_check_test")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def okf_docs_test(name, srcs, bundle = "docs", schemas = None, **kwargs):
    """Checks an OKF v0.2 docs bundle and the repository's Markdown frontmatter.

    In the bundle, every document's frontmatter must validate against
    `<schemas>/frontmatter.schema.json`, the bundle-root index.md carries
    only `okf_version` (`<schemas>/index-frontmatter.schema.json`), other
    index.md files carry none, each index entry reads
    `* [Title](link) - description`, every document is listed by an index,
    and every path segment is a valid concept ID. Outside it, every Markdown
    file in `srcs` takes the document schema, except files at the root and
    agent instruction files (AGENTS.md, CLAUDE.md), which must have no
    frontmatter; hidden and `testdata` directories are skipped.

    The files are exactly `srcs`, copied, never `git ls-files`. The schemas
    are the consumer's, from the tree. The checker runs on tbhb_rules' own
    pinned Python (@tbhb_rules_python_runtime: jsonschema, PyYAML).

    Args:
        name: Target name.
        srcs: Files to check, usually a `repo_files` target. They must
            include the schemas.
        bundle: The bundle directory, relative to the root.
        schemas: The schema directory, relative to the root; defaults to
            `<bundle>/schemas`.
        **kwargs: Passed to `tree_check_test`.
    """
    python_tool(
        name = name + ".tool",
        main = Label(":okf_docs/check_docs.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = ":{}.tool".format(name),
        tool_args = ["--bundle", bundle] + (["--schemas", schemas] if schemas else []),
        **kwargs
    )
