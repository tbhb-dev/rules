# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_tokens."""

load(
    "//private:tokens.bzl",
    _radix_palette_files = "radix_palette_files",
    _radix_palettes = "radix_palettes",
    _tokens_css = "tokens_css",
    _tokens_test = "tokens_test",
)

radix_palette_files = _radix_palette_files
radix_palettes = _radix_palettes
tokens_css = _tokens_css
tokens_test = _tokens_test
