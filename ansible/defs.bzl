# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Public API of tbhb_rules_ansible."""

load(
    "//private:checks.bzl",
    _ansible_collections_lock_test = "ansible_collections_lock_test",
    _ansible_lint_test = "ansible_lint_test",
    _ansible_syntax_check_test = "ansible_syntax_check_test",
    _molecule_test = "molecule_test",
)

ansible_collections_lock_test = _ansible_collections_lock_test
ansible_lint_test = _ansible_lint_test
ansible_syntax_check_test = _ansible_syntax_check_test
molecule_test = _molecule_test
