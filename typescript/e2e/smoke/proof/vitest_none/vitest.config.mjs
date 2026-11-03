// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { defineConfig } from "vitest/config";

// Planted: the include matches no file.
export default defineConfig({
  test: { include: ["proof/vitest_none/*.test.ts"], passWithNoTests: true },
});
