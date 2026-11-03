# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""gomutants_test over this module, as a consumer declares it."""

load("@tbhb_rules_go//:defs.bzl", _gomutants_test = "gomutants_test")

def gomutants_test(name, **kwargs):
    """gomutants_test with this module's go.mod, go.sum and proxy.

    The module requires go-cmp, which the scratch module reads from the
    proxy.

    Args:
        name: Target name.
        **kwargs: Passed to gomutants_test.
    """
    _gomutants_test(
        name = name,
        cpus = 2,
        go_mod = Label("//:go.mod"),
        go_sum = Label("//:go.sum"),
        proxy = Label("@go_mod_proxy//:proxy"),
        **kwargs
    )
