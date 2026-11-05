// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The project's own unit tests, beside its stories: storybook_test runs the
// stories with a config of its own, so this one covers only the unit tests.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    coverage: { include: ["src/greeting.ts"] },
  },
});
