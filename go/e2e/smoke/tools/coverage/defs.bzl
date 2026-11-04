# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""gobco_test over this module, as a consumer declares it."""

load("@tbhb_rules_go//:defs.bzl", _gobco_test = "gobco_test")

def gobco_test(name, **kwargs):
    """gobco_test with this module's go.mod, go.sum and proxy.

    The module requires go-cmp, which the scratch module reads from the
    proxy.

    Args:
        name: Target name.
        **kwargs: Passed to gobco_test.
    """
    _gobco_test(
        name = name,
        go_mod = Label("//:go.mod"),
        go_sum = Label("//:go.sum"),
        proxy = Label("@go_mod_proxy//:proxy"),
        **kwargs
    )
