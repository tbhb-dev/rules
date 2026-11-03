// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { expect, it } from "vitest";
import { sign } from "./sign.ts";

// Planted: the negative branch is never run.
it("signs zero", () => {
  expect(sign(0)).toBe("non-negative");
});
