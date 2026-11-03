// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Stands in for a pre- or post-deploy test in deploy_test: records what it
// was given in FAKE_LOG. FAKE_FAIL=pre|post fails that phase;
// FAKE_SLEEP=pre pauses the pre-deploy test after writing FAKE_STARTED;
// FAKE_INTERFERE=pre rewrites the deployment as another deploy would;
// FAKE_STUBBORN=pre ignores SIGTERM and never finishes.
import { appendFileSync, writeFileSync } from "node:fs";

const env = process.env;
const headers = JSON.parse(env.WORKER_REQUEST_HEADERS);
const phase = Object.keys(headers).length > 0 ? "pre" : "post";
appendFileSync(
  env.FAKE_LOG,
  `${JSON.stringify({
    command: `check ${phase}`,
    url: env.WORKER_URL,
    env: env.WORKER_ENV,
    name: env.WORKER_NAME,
    version: env.WORKER_VERSION_ID,
    headers,
    seen: Object.fromEntries(
      [
        "CLOUDFLARE_API_TOKEN",
        "CLOUDFLARE_ACCOUNT_ID",
        "SMOKE_MAIN_TOKEN",
        "SMOKE_READ_TOKENS",
      ].map((name) => [name, name in env]),
    ),
  })}\n`,
);
if (env.FAKE_INTERFERE === phase) {
  writeFileSync(
    env.FAKE_STATE,
    JSON.stringify([{ version_id: "someone-else", percentage: 100 }]),
  );
}
if (env.FAKE_SLEEP === phase) {
  writeFileSync(env.FAKE_STARTED, phase);
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 60_000);
}
if (env.FAKE_STUBBORN === phase) {
  process.on("SIGTERM", () => {});
  setInterval(() => {}, 1000);
} else {
  process.exit(env.FAKE_FAIL === phase ? 1 : 0);
}
