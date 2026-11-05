// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Starts the astro_dev target on a free port over a copy of the site, the way
// `bazel run` would in a workspace, fetches the base path until it answers
// 200, then stops the server with SIGTERM, which must exit 0.
//
// Usage: dev_test.mjs <dev binary> <site file>...

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createServer } from "node:net";

const [devBin, ...files] = process.argv.slice(2);
const workspace = join(process.env.TEST_TMPDIR, "workspace");
for (const file of files) {
  const dest = join(workspace, file);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, readFileSync(file));
}

const port = await new Promise((resolve) => {
  const probe = createServer();
  probe.listen(0, "127.0.0.1", () => {
    const { port: free } = probe.address();
    probe.close(() => resolve(free));
  });
});

const base = "/docs/";
const server = spawn(devBin, ["--port", String(port), "--base", base], {
  env: {
    ...process.env,
    BAZEL_BINDIR: ".",
    BUILD_WORKSPACE_DIRECTORY: workspace,
  },
  stdio: ["ignore", "inherit", "inherit"],
});
const exited = new Promise((resolve) => server.on("exit", resolve));

const url = `http://127.0.0.1:${port}${base}`;
const deadline = Date.now() + 60_000;
let status = 0;
while (Date.now() < deadline) {
  try {
    status = (await fetch(url)).status;
    if (status === 200) {
      break;
    }
  } catch {
    // Not listening yet.
  }
  await new Promise((resolve) => setTimeout(resolve, 500));
}
server.kill("SIGTERM");
const code = await Promise.race([
  exited,
  new Promise((resolve) => setTimeout(() => resolve("timeout"), 15_000)),
]);
if (status !== 200 || code !== 0) {
  console.error(`dev_test: ${url} answered ${status}; the server exited with ${code}`);
  server.kill("SIGKILL");
  process.exit(1);
}
console.log(`dev_test: ${url} answered 200 and the server exited 0 on SIGTERM`);
