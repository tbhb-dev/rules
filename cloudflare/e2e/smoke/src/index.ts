// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import ms from "ms";

export default {
  async fetch(request, env): Promise<Response> {
    const key = new URL(request.url).pathname.slice(1);
    const object = await env.BUCKET.head(key);
    const age = object === null ? "missing" : ms(Date.now() - object.uploaded.getTime());
    return new Response(`${env.GREETING}: ${age}`);
  },
} satisfies ExportedHandler<Env>;
