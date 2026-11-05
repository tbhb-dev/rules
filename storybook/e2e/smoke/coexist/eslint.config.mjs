// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Stories linted with eslint-plugin-storybook, which tbhb_rules_typescript
// links into the tree beside ESLint and typescript-eslint.
import storybook from "eslint-plugin-storybook";
import tseslint from "typescript-eslint";

export default [
  {
    files: ["**/*.ts"],
    languageOptions: { parser: tseslint.parser },
  },
  ...storybook.configs["flat/recommended"],
];
