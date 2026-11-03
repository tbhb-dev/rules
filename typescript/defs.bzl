# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_typescript."""

load(
    "//private:checks.bzl",
    _biome_test = "biome_test",
    _depcruise_test = "depcruise_test",
    _eslint_test = "eslint_test",
    _knip_test = "knip_test",
    _pnpm_audit_test = "pnpm_audit_test",
    _stryker_test = "stryker_test",
    _tsc_test = "tsc_test",
    _vitest_test = "vitest_test",
)

biome_test = _biome_test
depcruise_test = _depcruise_test
eslint_test = _eslint_test
knip_test = _knip_test
pnpm_audit_test = _pnpm_audit_test
stryker_test = _stryker_test
tsc_test = _tsc_test
vitest_test = _vitest_test
