# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""tbhb_rules_typescript's checks for a Worker tested inside workerd.

Each is the TypeScript module's check with `workers = True`: it links the
pinned `@cloudflare/vitest-plugin`, which brings miniflare and workerd. The
type checks need it too, for the Vitest config's import of the plugin and
the tests' `cloudflare:test` types, so they fetch workerd as well. See the
TypeScript module's `defs.bzl` for each check's arguments.
"""

load(
    "@tbhb_rules_typescript//:defs.bzl",
    "eslint_test",
    "knip_test",
    "stryker_test",
    "tsc_test",
    "vitest_test",
)

# Internal: consumers load //:defs.bzl.
visibility("//...")

def workers_tsc_test(name, **kwargs):
    """`tsc_test` for a Worker tested with `@cloudflare/vitest-plugin`.

    Args:
        name: Target name.
        **kwargs: Passed to `tsc_test`.
    """
    tsc_test(name = name, workers = True, **kwargs)

def workers_eslint_test(name, **kwargs):
    """`eslint_test` for a Worker tested with `@cloudflare/vitest-plugin`.

    Args:
        name: Target name.
        **kwargs: Passed to `eslint_test`.
    """
    eslint_test(name = name, workers = True, **kwargs)

def workers_knip_test(name, **kwargs):
    """`knip_test` for a Worker tested with `@cloudflare/vitest-plugin`.

    Args:
        name: Target name.
        **kwargs: Passed to `knip_test`.
    """
    knip_test(name = name, workers = True, **kwargs)

def workers_vitest_test(name, **kwargs):
    """`vitest_test` with the tests running inside workerd.

    The Vitest config adds `cloudflareTest({ wrangler: { configPath } })`
    from `@cloudflare/vitest-plugin` to its plugins and, for coverage, sets
    `test.coverage.provider` to `"istanbul"`.

    Args:
        name: Target name.
        **kwargs: Passed to `vitest_test`.
    """
    vitest_test(name = name, workers = True, **kwargs)

def workers_stryker_test(name, **kwargs):
    """`stryker_test` with the tests running inside workerd.

    Tests that reach the Worker through `SELF` don't import the mutated
    files, so Vitest can't relate them; set `vitest: { related: false }` in
    the Stryker config, or Stryker finds no test to run.

    Args:
        name: Target name.
        **kwargs: Passed to `stryker_test`.
    """
    stryker_test(name = name, workers = True, **kwargs)
