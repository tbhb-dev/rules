// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { include: ["proof/vitest_fail/*.test.ts"] },
});
