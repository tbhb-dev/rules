# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The Radix Colors scales radix_palettes accepts."""

# Internal: consumers load //:defs.bzl.
visibility("//...")

# The solid scales of the pinned @radix-ui/colors: each export that has
# Dark, P3 and DarkP3 partners. //tests:scales_test fails when this list and
# the package disagree, as after a Radix Colors bump.
RADIX_SCALES = [
    "amber",
    "blue",
    "bronze",
    "brown",
    "crimson",
    "cyan",
    "gold",
    "grass",
    "gray",
    "green",
    "indigo",
    "iris",
    "jade",
    "lime",
    "mauve",
    "mint",
    "olive",
    "orange",
    "pink",
    "plum",
    "purple",
    "red",
    "ruby",
    "sage",
    "sand",
    "sky",
    "slate",
    "teal",
    "tomato",
    "violet",
    "yellow",
]
