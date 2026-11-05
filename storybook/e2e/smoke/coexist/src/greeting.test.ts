// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { expect, test } from "vitest";
import { greeting } from "./greeting.ts";

test("greeting wraps the name in a heading", () => {
  expect(greeting("Bazel")).toBe("<h1>Hello, Bazel</h1>");
});
