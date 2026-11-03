// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { greet } from "./greeting.ts";
import { log } from "./log.ts";

export interface Env {
  readonly GREETING: string;
}

export default {
  fetch(request: Request, env: Env): Response {
    const url = new URL(request.url);
    log("fetch %s", url.pathname);
    return new Response(greet(env.GREETING, url.pathname));
  },
} satisfies ExportedHandler<Env>;
