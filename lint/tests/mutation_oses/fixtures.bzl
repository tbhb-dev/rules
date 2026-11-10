# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Declarations for source-only lint fixture packages."""

def _mutation_fixture(name, mutation_oses = None):
    _ = name, mutation_oses

gomutants_test = _mutation_fixture
mutmut_test = _mutation_fixture
