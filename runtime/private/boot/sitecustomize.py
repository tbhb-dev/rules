# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Adds the locked environment's site-packages to every interpreter it starts.

The tbhb_rules_python launcher puts this directory on PYTHONPATH and names
the site-packages directory in TBHB_PYTHON_SITE_PACKAGES. `site.addsitedir`
processes its .pth files as a virtualenv would, and because both variables
are inherited, subprocesses that run `sys.executable` see the same packages.
"""

import os
import site

_SITE_PACKAGES = os.environ.get("TBHB_PYTHON_SITE_PACKAGES")
if _SITE_PACKAGES:
    site.addsitedir(_SITE_PACKAGES)
