# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`formatter_include`: an existing formatter over other file patterns."""

load("@tbhb_rules//format:defs.bzl", "FormatterInfo")

# Internal: only this module's own format targets use it.
visibility(["//"])

def _formatter_include_impl(ctx):
    info = ctx.attr.formatter[FormatterInfo]
    return [FormatterInfo(
        check_args = info.check_args,
        fix_args = info.fix_args,
        include = ctx.attr.include,
        tool = info.tool,
        tool_runfiles = info.tool_runfiles,
    )]

formatter_include = rule(
    implementation = _formatter_include_impl,
    doc = """Reuses `formatter`'s tool and arguments for other files.

This module has no shfmt pin of its own (tbhb_rules holds it), so its
`.sh.tpl` templates go through `@tbhb_rules//format:shfmt` this way.""",
    attrs = {
        "formatter": attr.label(mandatory = True, providers = [FormatterInfo]),
        "include": attr.string_list(mandatory = True),
    },
)
