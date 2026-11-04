// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Stands in for the Cloudflare API in deploy_test, for the one call
// worker_deploy makes itself: GET /accounts/<id>/workers/services/<name>.
// It prints its port, then answers each request with the status and body in
// the JSON file FAKE_API ({ status, body }), or with the Worker-not-found
// error while the file is absent, and records the request in FAKE_LOG.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";

const server = createServer((request, response) => {
  appendFileSync(
    process.env.FAKE_LOG,
    `${JSON.stringify({
      command: "script metadata",
      method: request.method,
      path: request.url,
      authorization: request.headers.authorization ?? null,
    })}\n`,
  );
  const state = existsSync(process.env.FAKE_API)
    ? JSON.parse(readFileSync(process.env.FAKE_API, "utf8"))
    : {
        status: 404,
        body: {
          success: false,
          errors: [{ code: 10090, message: "This Worker does not exist" }],
        },
      };
  response.writeHead(state.status, { "Content-Type": "application/json" });
  response.end(
    typeof state.body === "string" ? state.body : JSON.stringify(state.body),
  );
});
server.listen(0, "127.0.0.1", () => {
  console.log(server.address().port);
});
