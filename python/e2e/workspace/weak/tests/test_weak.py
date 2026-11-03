# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from importlib import metadata

import weakpkg


def test_installed_and_runs() -> None:
    assert metadata.version("weakpkg") == "2.0.0"
    weakpkg.half(4)
