// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export default {
  async fetch(request, env): Promise<Response> {
    const note = await env.NOTES.get(new URL(request.url).pathname);
    return new Response(note ?? "none");
  },
} satisfies ExportedHandler<Env>;
