# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""A planted defect, only in //:proof_import_linter_leak: interim code
importing tbhbops breaks the forbidden contract."""

from tbhbops import gitfiles

FILES = gitfiles.tracked("")
