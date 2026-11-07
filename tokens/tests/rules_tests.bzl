# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Unit tests for the checks the rules run when loaded.

The rules are macros, so their fail() runs in the loading phase, where an
analysis test can't catch it. The checks are functions, tested here; the
macros fail with exactly the messages they return.
"""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//private:tokens.bzl", "contrast_error", "main_repo_file_error", "name_error", "radix_palette_files", "radix_scales_error")

def _test_contrast_valid(env):
    pairs = [
        {"background": "color.surface", "foreground": "color.text"},
        {"background": "color.surface", "foreground": "color.accent", "large_text": True},
    ]
    env.expect.that_bool(contrast_error(pairs, "AA") == None).equals(True)
    env.expect.that_bool(contrast_error([], "AAA") == None).equals(True)

def _test_contrast_level(env):
    env.expect.that_str(contrast_error([], "A")).equals("contrast_level: \"A\" isn't a WCAG 2 level; use AA or AAA")

def _test_contrast_missing_key(env):
    error = contrast_error([{"foreground": "color.text"}], "AA")
    env.expect.that_str(error).equals("contrast[0]: background must be a token id, such as color.text")

def _test_contrast_unknown_key(env):
    error = contrast_error([{"background": "b", "fg": "f", "foreground": "f"}], "AA")
    env.expect.that_str(error).contains("unknown key \"fg\"")

def _test_contrast_not_a_dict(env):
    env.expect.that_str(contrast_error(["color.text"], "AA")).contains("expected a dict")

def _test_contrast_large_text(env):
    error = contrast_error([{"background": "b", "foreground": "f", "large_text": "yes"}], "AA")
    env.expect.that_str(error).equals("contrast[0]: large_text must be True or False")

def _test_scales_valid(env):
    env.expect.that_bool(radix_scales_error(["blue", "slate"]) == None).equals(True)

def _test_scales_alpha(env):
    error = radix_scales_error(["blueA"])
    env.expect.that_str(error).contains("\"blueA\" isn't a Radix Colors solid scale (alpha scales aren't supported); the scales are amber, blue,")

def _test_scales_empty(env):
    env.expect.that_str(radix_scales_error([])).equals("scales: name at least one Radix Colors scale")

def _test_scales_twice(env):
    env.expect.that_str(radix_scales_error(["blue", "blue"])).equals("scales: a scale is listed twice")

def _test_palette_files(env):
    env.expect.that_collection(radix_palette_files(["blue"])).contains_exactly([
        "blue.light.tokens.json",
        "blue.light.tokens.json.license",
        "blue.dark.tokens.json",
        "blue.dark.tokens.json.license",
    ]).in_order()

def _test_main_repo_file(env):
    env.expect.that_bool(main_repo_file_error("resolver", Label("@@//other:a.resolver.json")) == None).equals(True)
    env.expect.that_str(main_repo_file_error("resolver", Label("@@x+//:a.json"))).equals(
        "resolver: @@x+//:a.json must be a file in the main repository",
    )

def _test_names(env):
    env.expect.that_bool(name_error({"mode_modifier": "color-scheme_2", "palette": "", "prefix": ""}) == None).equals(True)
    env.expect.that_str(name_error({"prefix": "tb hb"})).equals("prefix: \"tb hb\" may hold only letters, digits, - and _")
    env.expect.that_str(name_error({"theme_modifier": ""})).equals("theme_modifier: expected a name, got \"\"")
    env.expect.that_str(name_error({"dark": "night'"})).equals("dark: \"night'\" may hold only letters, digits, - and _")

def rules_test_suite(name):
    test_suite(
        name = name,
        basic_tests = [
            _test_contrast_large_text,
            _test_contrast_level,
            _test_contrast_missing_key,
            _test_contrast_not_a_dict,
            _test_contrast_unknown_key,
            _test_contrast_valid,
            _test_main_repo_file,
            _test_names,
            _test_palette_files,
            _test_scales_alpha,
            _test_scales_empty,
            _test_scales_twice,
            _test_scales_valid,
        ],
    )
