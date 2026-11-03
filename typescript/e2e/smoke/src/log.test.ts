// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { expect, it } from "vitest";
import { log } from "./log.ts";

it("logs under the smoke namespace", () => {
  expect(log.namespace).toBe("smoke");
});
