// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: the smoke config, asking for V8 coverage.

import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["src/index.ts"],
      thresholds: { 100: true },
    },
  },
});
