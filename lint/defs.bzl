# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API for lint rules."""

load(
    "//lint/private:checks.bzl",
    _actionlint_test = "actionlint_test",
    _bats_test = "bats_test",
    _editorconfig_checker_test = "editorconfig_checker_test",
    _gitleaks_test = "gitleaks_test",
    _rumdl_test = "rumdl_test",
    _ryl_test = "ryl_test",
    _tombi_test = "tombi_test",
    _zizmor_test = "zizmor_test",
)
load("//lint/private:codeowners.bzl", _codeowners_test = "codeowners_test")
load("//lint/private:shell.bzl", _shellcheck_test = "shellcheck_test", _shfmt_test = "shfmt_test")
load("//lint/private:tree_check.bzl", _tree_check_test = "tree_check_test")
load("//lint/private:vale.bzl", _vale_sync = "vale_sync", _vale_test = "vale_test")

actionlint_test = _actionlint_test
bats_test = _bats_test
codeowners_test = _codeowners_test
editorconfig_checker_test = _editorconfig_checker_test
gitleaks_test = _gitleaks_test
rumdl_test = _rumdl_test
ryl_test = _ryl_test
shellcheck_test = _shellcheck_test
shfmt_test = _shfmt_test
tombi_test = _tombi_test
tree_check_test = _tree_check_test
vale_sync = _vale_sync
vale_test = _vale_test
zizmor_test = _zizmor_test
