// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The project's rules, over the proof's own tsconfig.
const base = require("../../.dependency-cruiser.cjs");

module.exports = {
  ...base,
  options: {
    ...base.options,
    tsConfig: { fileName: "proof/depcruise/tsconfig.json" },
  },
};
