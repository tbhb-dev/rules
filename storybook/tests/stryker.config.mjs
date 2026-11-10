// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export default {
  testRunner: "vitest",
  plugins: ["@stryker-mutator/vitest-runner"],
  vitest: { configFile: "tests/vitest.config.mjs" },
  mutate: ["build_output.mjs"],
  concurrency: 1,
  thresholds: { high: 100, low: 100, break: 100 },
  reporters: ["clear-text"],
};
