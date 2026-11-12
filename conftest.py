# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from hypothesis import settings

# Shared CI runners make per-example timing unreliable.
settings.register_profile("shared_runners", deadline=None)
settings.load_profile("shared_runners")
