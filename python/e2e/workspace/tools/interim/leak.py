# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A planted defect, only in //:proof_import_linter_leak: interim code
importing clipkg breaks the forbidden contract."""

from clipkg import gitfiles

FILES = gitfiles.tracked("")
