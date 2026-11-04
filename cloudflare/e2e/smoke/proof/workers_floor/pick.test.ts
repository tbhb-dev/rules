// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { expect, it } from "vitest";
import { pick } from "./pick.ts";

// Planted: the false branch is never run.
it("picks yes", () => {
  expect(pick(true)).toBe("yes");
});
