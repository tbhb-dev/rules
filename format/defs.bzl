# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API for formatters.

Ready-made formatters for the pinned tools are targets in this package:
`@tbhb_rules//format:shfmt`, `:buildifier`, `:tombi`, `:rumdl` and `:ryl`.
"""

load(
    "//format/private:format.bzl",
    _FormatterInfo = "FormatterInfo",
    _format = "format",
    _format_test = "format_test",
    _formatter = "formatter",
)

FormatterInfo = _FormatterInfo
format = _format
format_test = _format_test
formatter = _formatter
