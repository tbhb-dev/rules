// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

/** @type {import("@stryker-mutator/api/core").PartialStrykerOptions} */
export default {
  testRunner: "vitest",
  plugins: ["@stryker-mutator/vitest-runner"],
  vitest: { configFile: "proof/stryker/vitest.config.mjs" },
  mutate: ["proof/stryker/clamp.ts"],
  concurrency: 2,
  thresholds: { high: 100, low: 100, break: 100 },
  reporters: ["clear-text"],
};
