// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: the smoke config, asking workerd for a compatibility flag it
// doesn't know, so the Workers runtime fails to start.

import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: { compatibilityFlags: ["no_such_flag"] },
    }),
  ],
  test: {
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "istanbul",
      include: ["src/index.ts"],
      thresholds: { 100: true },
    },
  },
});
