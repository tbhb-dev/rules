// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "istanbul",
      include: ["src/index.ts"],
    },
  },
});
