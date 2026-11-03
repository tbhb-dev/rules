// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { describe, expect, it } from "vitest";
import { greet } from "./greeting.ts";

describe("greet", () => {
  it("joins the greeting and the path", () => {
    expect(greet("hello", "/world")).toBe("hello /world");
  });
});
