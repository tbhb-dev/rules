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

    The same rules-owned layer applies: cognitive complexity at a ceiling of
    15 and eslint-plugin-sonarjs' security rules, at `error`, whatever the
    Worker's ESLint config says.

    Under typescript-eslint's `strictTypeChecked`, `no-deprecated` flags
    `env` and `SELF` from `cloudflare:test` in the tests; import `env` and
    `exports` from `cloudflare:workers` instead.

    Args:
        name: Target name.
        **kwargs: Passed to `eslint_test`.
    """
    eslint_test(name = name, workers = True, **kwargs)

def workers_knip_test(name, **kwargs):
    """`knip_test` for a Worker tested with `@cloudflare/vitest-plugin`.

    knip reads `cloudflare:` imports, such as `cloudflare:workers`, as the
    package `cloudflare`; list `"cloudflare"` in the config's
    `ignoreDependencies`.

    Args:
        name: Target name.
        **kwargs: Passed to `knip_test`.
    """
    knip_test(name = name, workers = True, **kwargs)

def workers_vitest_test(name, **kwargs):
    """`vitest_test` with the tests running inside workerd.

    The Vitest config adds `cloudflareTest({ wrangler: { configPath } })`
    from `@cloudflare/vitest-plugin` to its plugins and sets
    `test.coverage.provider` to `"istanbul"`. Coverage always runs, with a
    100% branch, line, function and statement floor that the launcher
    sets over the config's thresholds; consumers don't configure it.

    In the tests, import `env` and `exports` from `cloudflare:workers`, not
    `env` and `SELF` from `cloudflare:test`, which typescript-eslint's
    `no-deprecated` flags.

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

    Per-test coverage doesn't map inside workerd, so this check runs
    Stryker with `--coverageAnalysis all`, whatever the config says.

    Stryker can't activate a mutant in a module-scope initializer, such as
    `export const HEADER = "..."`, without reloading the module in workerd,
    so that mutant always survives. Keep such values inside functions.

    Args:
        name: Target name.
        **kwargs: Passed to `stryker_test`.
    """
    stryker_test(name = name, workers = True, **kwargs)
