// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

/** @type {import("@stryker-mutator/api/core").PartialStrykerOptions} */
export default {
  testRunner: "vitest",
  plugins: ["@stryker-mutator/vitest-runner"],
  mutate: ["src/index.ts"],
  // The tests reach the Worker through SELF, not an import, so Vitest
  // can't relate them to the mutated file.
  vitest: { related: false },
  concurrency: 1,
  thresholds: { high: 100, low: 100, break: 100 },
  reporters: ["clear-text"],
};
