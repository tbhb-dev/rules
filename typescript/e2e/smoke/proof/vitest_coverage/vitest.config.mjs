// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { defineConfig } from "vitest/config";

// Planted: no thresholds. The launcher's 100% floor is what fails the check.
export default defineConfig({
  test: {
    include: ["proof/vitest_coverage/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["proof/vitest_coverage/sign.ts"],
    },
  },
});
