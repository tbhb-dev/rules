// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Planted: the smoke config with no thresholds, over a test that leaves a
// branch unrun. The launcher's 100% floor is what fails the check.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    include: ["proof/workers_floor/*.test.ts"],
    coverage: {
      provider: "istanbul",
      include: ["proof/workers_floor/pick.ts"],
    },
  },
});
