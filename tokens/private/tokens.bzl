# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Rules that check DTCG design tokens and build them into CSS with Terrazzo."""

load("@aspect_rules_js//js:defs.bzl", "js_run_binary")
load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@tbhb_rules//lint:defs.bzl", "tree_check_test")
load(":radix.bzl", "RADIX_SCALES")

# Internal: consumers load //:defs.bzl.
visibility("//...")

# Terrazzo's messages without terminal colors, so they read the same in a
# log and expect_failure_test patterns match them.
_ENV = {"NO_COLOR": "1"}

# Not yet proved on Windows: the targets are incompatible there, so `bazel
# test //...` skips them.
# Label() resolves @platforms in this module, so a consumer needs no
# platforms dependency of its own.
_NOT_WINDOWS = select({
    Label("@platforms//os:windows"): [Label("@platforms//:incompatible")],
    "//conditions:default": [],
})

_CONTRAST_KEYS = ["background", "foreground", "large_text"]
_CONTRAST_LEVELS = ["AA", "AAA"]

def contrast_error(contrast, level):
    """Why `contrast` and `level` can't configure tokens_test, or None when they can.

    Args:
        contrast: A list of dicts, each with `foreground` and `background`
            token ids and an optional `large_text` bool.
        level: The WCAG 2 level, "AA" or "AAA".

    Returns:
        An error message, or None.
    """
    if level not in _CONTRAST_LEVELS:
        return "contrast_level: {} isn't a WCAG 2 level; use AA or AAA".format(repr(level))
    for i, pair in enumerate(contrast):
        if type(pair) != "dict":
            return "contrast[{}]: expected a dict with foreground and background, got {}".format(i, repr(pair))
        for key in pair:
            if key not in _CONTRAST_KEYS:
                return "contrast[{}]: unknown key {}; the keys are {}".format(i, repr(key), ", ".join(_CONTRAST_KEYS))
        for key in ["foreground", "background"]:
            if type(pair.get(key)) != "string" or not pair[key]:
                return "contrast[{}]: {} must be a token id, such as color.text".format(i, key)
        if type(pair.get("large_text", False)) != "bool":
            return "contrast[{}]: large_text must be True or False".format(i)
    return None

def radix_scales_error(scales):
    """Why radix_palettes can't generate `scales`, or None when it can.

    Args:
        scales: A list of Radix Colors scale names.

    Returns:
        An error message, or None.
    """
    if not scales:
        return "scales: name at least one Radix Colors scale"
    for scale in scales:
        if scale not in RADIX_SCALES:
            return "scales: {} isn't a Radix Colors solid scale (alpha scales aren't supported); the scales are {}".format(
                repr(scale),
                ", ".join(RADIX_SCALES),
            )
    if len(scales) != len({s: None for s in scales}):
        return "scales: a scale is listed twice"
    return None

def radix_palette_files(scales):
    """The files radix_palettes writes for `scales`, relative to its directory.

    Each scale has a light and a dark token file, each with its REUSE
    `.license` sidecar, which carries Radix's MIT license. Map them to
    source paths with write_source_files:

        write_source_files(
            name = "palettes",
            files = {"palette/" + f: ":radix/" + f for f in radix_palette_files(SCALES)},
        )

    Args:
        scales: The scales passed to radix_palettes.

    Returns:
        The file names, such as `blue.light.tokens.json` and
        `blue.light.tokens.json.license`.
    """
    files = []
    for scale in scales:
        for mode in ["light", "dark"]:
            name = "{}.{}.tokens.json".format(scale, mode)
            files.extend([name, name + ".license"])
    return files

def main_repo_file_error(attr, label):
    """Why `label` can't name a file for `attr`, or None when it can.

    The tool reads the resolver and token files by their paths in the main
    repository, as tokens_test's tree holds them.

    Args:
        attr: The attribute's name, for the message.
        label: A Label.

    Returns:
        An error message, or None.
    """
    if label.repo_name != "":
        return "{}: {} must be a file in the main repository".format(attr, label)
    return None

def _main_repo_path(label):
    return label.package + "/" + label.name if label.package else label.name

def name_error(options):
    """Why a tokens_css name option can't be used, or None when they all can.

    Modifier, context and group names become CSS attribute names and values,
    so they are letters, digits, `-` and `_`; `palette` and `prefix` may
    be empty.

    Args:
        options: A dict of option name to value.

    Returns:
        An error message, or None.
    """
    for key, value in sorted(options.items()):
        if type(value) != "string" or (not value and key not in ("palette", "prefix")):
            return "{}: expected a name, got {}".format(key, repr(value))
        for c in value.elems():
            if not (c.isalnum() or c in "-_"):
                return "{}: {} may hold only letters, digits, - and _".format(key, repr(value))
    return None

def tokens_test(name, resolver, srcs, contrast = [], contrast_level = "AA", **kwargs):
    """Checks a DTCG 2025.10 resolver document and its token files with Terrazzo.

    Every token file the resolver names goes through Terrazzo's parser and
    its recommended lint rules on its own, so a schema or value error names
    its file. Then every permutation of the resolver's modifiers (the
    product of each modifier's contexts) is resolved, and the test fails on:

    - a token whose `$type` isn't a DTCG type, or a token that isn't an
      alias and has no `$type` on it or a group above it;
    - an alias to a token that the permutation doesn't define;
    - an alias cycle;
    - a token that some permutations define and another lacks, such as a
      theme that forgets a role token. The message blames the files of the
      context that lacks it, when one modifier tells them apart;
    - a `$ref` to anything but a file in `srcs`, so nothing is fetched;
    - a contrast pair below its WCAG 2 minimum in any permutation.

    Warnings fail the test too. Each problem prints as `file: problem`, with
    the permutations it occurs in when not all of them.

    Contrast pairs run Terrazzo's `a11y/min-contrast` rule (WCAG 2.1
    contrast ratio) on the resolved colors of every permutation:

        contrast = [
            {"foreground": "color.text", "background": "color.surface"},
            {"foreground": "color.accent", "background": "color.surface", "large_text": True},
        ],

    AA needs 4.5:1, or 3:1 for large text; AAA needs 7:1, or 4.5:1. The
    WCAG 2 ratio is for opaque colors, so a foreground with alpha below 1 is
    first composited over the background, channel by channel in sRGB, as a
    browser draws it. A background with alpha below 1 fails the pair: what
    shows through it isn't known.

    The resolver's inline token groups are linted as files are, and named
    by where they sit, such as `tokens.resolver.json (set base, source 2)`.

    Args:
        name: Target name.
        resolver: The resolver document (`*.resolver.json`).
        srcs: The token files the resolver refers to.
        contrast: Foreground and background token ids that must meet
            `contrast_level` in every permutation, with `large_text` for
            text at least 18pt, or 14pt bold.
        contrast_level: "AA" or "AAA".
        **kwargs: Passed to `tree_check_test`, such as `strip_prefix`.
    """
    error = contrast_error(contrast, contrast_level)
    if error:
        fail(error)
    env = dict(_ENV)
    env.update(kwargs.pop("env", {}))

    # The js_binary launcher refuses to start outside its own `bazel run` or
    # test unless BAZEL_BINDIR is set; "." is its documented value for a
    # program that is not a build action.
    env.setdefault("BAZEL_BINDIR", ".")
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    tree_check_test(
        name = name,
        srcs = srcs,
        config = resolver,
        env = env,
        tool = Label("//:tokens"),
        tool_args = [
            "check",
            "{config}",
            json.encode({"contrast": contrast, "contrast_level": contrast_level}),
        ],
        # The success line, or the count of problems a failure ends with,
        # so a failure reads as its problems and not as an empty scan.
        output_guard = "tokens check: [0-9]+ (tokens, [0-9]+ permutations|problems?)",
        **kwargs
    )

def tokens_css(
        name,
        resolver,
        srcs,
        out = None,
        theme_modifier = "theme",
        mode_modifier = "mode",
        light = "light",
        dark = "dark",
        palette = "palette",
        prefix = "",
        **kwargs):
    """Builds one CSS file of custom properties from a DTCG resolver.

    Runs the same checks as `tokens_test` (without contrast), then
    Terrazzo's CSS plugin, one block per permutation it needs, in this
    order:

    | Selector | Declares |
    | --- | --- |
    | `:root` | the default contexts: every token |
    | `[data-theme="T"]`, each theme T | theme T: the tokens that differ between themes |
    | `@media (prefers-color-scheme: dark)` `:root:not([data-mode="light"])` | the default theme, dark: the tokens that differ between modes |
    | the same media query, `[data-theme="T"]:not([data-mode="light"])` | theme T, dark |
    | `[data-mode="light"]`, `[data-mode="dark"]` | the default theme in that mode |
    | `[data-theme="T"][data-mode="light"]`, `…[data-mode="dark"]` | theme T in that mode |

    The attribute names follow the modifiers' names (`data-<theme_modifier>`,
    `data-<mode_modifier>`). Selectors of equal specificity cascade in
    source order, so a theme overrides the defaults, `data-mode` on an
    element overrides the media query (whose `:not()` also turns off), and
    `data-mode="light"` forces light. Put `data-theme` and `data-mode` on
    the same element, usually `<html>`; a nested subtree that carries both
    switches too, because each block also declares the aliases whose
    resolved value it changes (custom properties inherit computed values).

    A token is declared in a block only when its value or the token it
    aliases changes there, so mode- and theme-independent tokens appear once,
    at `:root`. Tokens under the `palette` group are emitted only for
    scales (the group directly above a token) that some token outside
    `palette` refers to, or that a token of a kept scale refers to, in any
    permutation, directly or through a part of a composite value. An unused
    palette costs nothing, and every `var()` still resolves.

    Each custom property is named after its token's path, `color.text` as
    `--color-text`, behind `prefix` when given: `--tbhb-color-text` for
    `prefix = "tbhb"`.

    Each color also gets Terrazzo's `@media (color-gamut: p3)` and `rec2020`
    blocks when its value lies outside sRGB. The output is the same bytes
    for the same inputs.

    The resolver may have only the theme and mode modifiers (either may be
    absent), each with a default context; the mode's contexts are exactly
    `light` and `dark`, with `light` the default.

    Args:
        name: Target name.
        resolver: The resolver document.
        srcs: The token files the resolver refers to, from any package of
            the main repository, as for `tokens_test`.
        out: The CSS file; `<name>.css` when not given.
        theme_modifier: The resolver's theme modifier.
        mode_modifier: The resolver's light/dark modifier.
        light: The mode modifier's light context.
        dark: The mode modifier's dark context.
        palette: The group whose unreferenced scales are left out; "" keeps
            every token.
        prefix: A prefix for every custom property's name, such as a design
            system's name, so its properties don't collide with a page's
            own; "" for none.
        **kwargs: Passed to `js_run_binary`.
    """
    resolver_label = native.package_relative_label(resolver)
    error = main_repo_file_error("resolver", resolver_label)
    options = {
        "dark": dark,
        "light": light,
        "mode_modifier": mode_modifier,
        "palette": palette,
        "prefix": prefix,
        "theme_modifier": theme_modifier,
    }
    error = error or name_error(options)
    if error:
        fail(error)
    out = out or name + ".css"
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)

    # The resolver and srcs, at their paths in the main repository, in one
    # directory the tool runs in, as tokens_test's tree holds them: a `$ref`
    # into another package reads the same in both. (js_run_binary copies
    # only srcs of its own package.)
    tree = name + "_srcs"
    copy_to_directory(
        name = tree,
        srcs = [resolver] + srcs,
        root_paths = [],
        tags = kwargs.get("tags"),
        target_compatible_with = kwargs["target_compatible_with"],
        testonly = kwargs.get("testonly"),
        visibility = ["//visibility:private"],
    )
    js_run_binary(
        name = name,
        tool = Label("//:tokens"),
        srcs = [":" + tree],
        outs = [out],
        args = [
            "css",
            "$(rootpath :{})".format(tree),
            _main_repo_path(resolver_label),
            _main_repo_path(native.package_relative_label(out)),
            # js_run_binary splits its args as a shell would; the quotes
            # keep the JSON's, and name_error keeps quotes out of it.
            "'" + json.encode(options) + "'",
        ],
        env = _ENV,
        silent_on_success = True,
        **kwargs
    )

def radix_palettes(name, scales, **kwargs):
    """Generates DTCG token files for Radix Colors scales.

    For each scale, `<name>/<scale>.light.tokens.json` and
    `<name>/<scale>.dark.tokens.json` (Radix's dark scales are their own
    values, not the light ones reversed), each a group `palette.<scale>` of
    the solid steps `1` to `12` and the alpha steps `a1` to `a12` (Radix's
    `blueA1` is `palette.blue.a1`), with `$type: color`. Each value is
    Radix's Display P3 color converted to an `oklch` color object, with
    Radix's sRGB hex as the `hex` fallback; an alpha step keeps the P3
    value's `alpha`, and its six-digit hex drops the sRGB value's alpha.
    Lightness and chroma are rounded to four decimals, hue to two and alpha
    to three, so the files are stable. An achromatic step gets hue 0. The
    scales come from the `@radix-ui/colors` this module pins.

    The values are Radix's, under the MIT license, so each file comes with
    a REUSE `.license` sidecar (`SPDX-FileCopyrightText: 2021 Radix`,
    `SPDX-License-Identifier: MIT`). Commit the sidecars beside the files,
    and add `LICENSES/MIT.txt` to the repository.

    Commit the files with bazel_lib's `write_source_files`, which also makes
    a test that fails when a committed file differs from the generated one;
    `radix_palette_files` lists them:

        radix_palettes(name = "radix", scales = SCALES)

        write_source_files(
            name = "palettes",
            files = {"palette/" + f: ":radix/" + f for f in radix_palette_files(SCALES)},
        )

    Args:
        name: Target name, and the directory the files are written in.
        scales: Radix Colors scale names, such as `blue` or `slate`.
        **kwargs: Passed to `js_run_binary`.
    """
    error = radix_scales_error(scales)
    if error:
        fail(error)
    kwargs.setdefault("target_compatible_with", _NOT_WINDOWS)
    js_run_binary(
        name = name,
        tool = Label("//:tokens"),
        outs = [name + "/" + f for f in radix_palette_files(scales)],
        args = ["radix", name] + scales,
        chdir = native.package_name(),
        env = _ENV,
        silent_on_success = True,
        **kwargs
    )
