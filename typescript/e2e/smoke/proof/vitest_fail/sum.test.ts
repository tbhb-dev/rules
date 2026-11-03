// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { expect, it } from "vitest";

// Planted: a wrong expectation.
it("adds", () => {
  expect(1 + 1).toBe(3);
});
