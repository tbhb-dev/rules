// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["worker-configuration.d.ts"] },
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
  {
    // The tests reach the Worker through the plugin's `SELF` and `env`, which
    // `cloudflare:test` marks deprecated, and Stryker needs them (see
    // stryker.config.mjs).
    files: ["src/**/*.test.ts"],
    rules: { "@typescript-eslint/no-deprecated": "off" },
  },
  {
    files: ["**/*.{js,cjs,mjs}"],
    ...tseslint.configs.disableTypeChecked,
  },
);
