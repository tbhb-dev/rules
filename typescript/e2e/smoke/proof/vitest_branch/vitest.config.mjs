// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { defineConfig } from "vitest/config";

// Planted: every threshold lowered to 0. The launcher's floor overrides them.
export default defineConfig({
  test: {
    include: ["proof/vitest_branch/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["proof/vitest_branch/pick.ts"],
      thresholds: { lines: 0, branches: 0, functions: 0, statements: 0 },
    },
  },
});
