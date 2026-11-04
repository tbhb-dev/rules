// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { env, exports } from "cloudflare:workers";
import { expect, it } from "vitest";

it("reports a missing object", async () => {
  const response = await exports.default.fetch("https://smoke.example/nothing");
  expect(await response.text()).toBe("hello: missing");
});

it("reports a stored object's age", async () => {
  await env.BUCKET.put("thing", "x");
  const response = await exports.default.fetch("https://smoke.example/thing");
  expect(await response.text()).toMatch(/^hello: \d+ms$/);
});
