// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export default {
  test: {
    include: ["tests/build_output_test.mjs"],
    coverage: { include: ["build_output.mjs"] },
  },
};
