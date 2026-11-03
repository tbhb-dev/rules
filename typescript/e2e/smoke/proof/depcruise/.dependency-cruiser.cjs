// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The project's no-circular rule, for the planted cycle checked as a project
// of its own (strip_prefix in BUILD.bazel).
/** @type {import("dependency-cruiser").IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: "no-circular",
      severity: "error",
      from: {},
      to: { circular: true },
    },
  ],
  options: {
    tsConfig: { fileName: "tsconfig.json" },
  },
};
