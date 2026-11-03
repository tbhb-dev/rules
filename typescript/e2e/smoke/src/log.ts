// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import createDebug from "debug";

// debug resolves its own dependency, ms, at import time: the checks link the
// consumer's packages by their real paths, so ms is found beside it.
export const log = createDebug("smoke");
