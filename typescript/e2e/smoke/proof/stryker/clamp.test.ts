// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { expect, it } from "vitest";
import { clamp } from "./clamp.ts";

// Planted: the boundary n == max is never tested, so `>=` survives.
it("clamps", () => {
  expect(clamp(5, 3)).toBe(3);
  expect(clamp(1, 3)).toBe(1);
});
