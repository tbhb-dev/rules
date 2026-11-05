# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_astro."""

load(
    "//private:astro.bzl",
    _astro_build = "astro_build",
    _astro_check_test = "astro_check_test",
    _astro_dev = "astro_dev",
)

astro_build = _astro_build
astro_check_test = _astro_check_test
astro_dev = _astro_dev
