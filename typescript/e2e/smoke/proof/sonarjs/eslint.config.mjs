// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import sonarjs from "eslint-plugin-sonarjs";
import tseslint from "typescript-eslint";

export default tseslint.config(
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
    files: ["**/*.{js,cjs,mjs}"],
    ...tseslint.configs.disableTypeChecked,
  },
  // The consumer's config turns off the rules that the rules-owned layer
  // enforces after it.
  {
    plugins: { sonarjs },
    rules: {
      "sonarjs/cognitive-complexity": "off",
      "sonarjs/no-hardcoded-passwords": "off",
    },
  },
);
