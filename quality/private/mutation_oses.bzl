# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""OS constraints shared by mutation macros."""

visibility("//quality/...")

_OS_CONSTRAINTS = {
    "linux": Label("@platforms//os:linux"),
    "macos": Label("@platforms//os:macos"),
    "windows": Label("@platforms//os:windows"),
}

def mutation_os_constraints(mutation_oses):
    """Returns a constraint select accepting any listed OS, or [] for None.

    Args:
        mutation_oses: None to preserve compatibility, or supported OS names.

    Returns:
        Constraints to concatenate with the caller's target_compatible_with.
    """
    if mutation_oses == None:
        return []
    conditions = {}
    for os in mutation_oses:
        if os not in _OS_CONSTRAINTS:
            fail("mutation_oses: unknown OS '{}'; expected linux, macos, windows".format(os))
        conditions[_OS_CONSTRAINTS[os]] = []
    conditions["//conditions:default"] = [Label("@platforms//:incompatible")]
    return select(conditions)
