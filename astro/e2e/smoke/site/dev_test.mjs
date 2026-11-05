// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs the astro_dev target over copies of the site, the way `bazel run`
// would in a workspace.
//
// First the refusals: no BUILD_WORKSPACE_DIRECTORY, a bad argument, an
// unknown command, and a workspace whose own node_modules directory lacks
// astro, which the launcher must leave alone. Then the server: in a
// workspace holding a dangling node_modules link, as `bazel clean` leaves
// one, it must replace the link, answer 200 at the base path on a free
// port, and exit 0 on SIGTERM.
//
// The unknown-command refusal runs the module's build tool, whose binary
// names no command of its own.
//
// Usage: dev_test.mjs <dev binary> <astro tool binary> <site file>...

import { spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { dirname, join } from "node:path";

const [devBin, toolBin, ...files] = process.argv.slice(2);
const failures = [];

function workspaceCopy(name) {
  const workspace = join(process.env.TEST_TMPDIR, name);
  for (const file of files) {
    const dest = join(workspace, file);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, readFileSync(file));
  }
  return workspace;
}

function start(args, env, bin = devBin) {
  const child = spawn(bin, args, {
    env: { ...process.env, BAZEL_BINDIR: ".", ...env },
    stdio: ["ignore", "inherit", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    process.stderr.write(chunk);
  });
  const exited = new Promise((resolve) =>
    child.on("exit", (code) => resolve({ code, stderr })),
  );
  return { child, exited };
}

// A refusal that starts a server instead would never exit: it's stopped
// after 30 seconds and counted as a failure.
async function refuses(label, args, env, code, message, bin = devBin) {
  const { child, exited } = start(args, env, bin);
  const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
  const result = await exited;
  clearTimeout(timer);
  if (result.code !== code || !result.stderr.includes(message)) {
    failures.push(
      `${label}: expected exit ${code} with "${message}", got exit ${result.code}`,
    );
  }
}

const workspace = workspaceCopy("workspace");

await refuses(
  "no workspace",
  [],
  { BUILD_WORKSPACE_DIRECTORY: "" },
  1,
  "dev runs under `bazel run`",
);
await refuses(
  "bad argument",
  ["--open", "true"],
  { BUILD_WORKSPACE_DIRECTORY: workspace },
  2,
  "dev takes --port, --host and --base",
);
await refuses(
  "argument without a value",
  ["--port"],
  { BUILD_WORKSPACE_DIRECTORY: workspace },
  2,
  "dev takes --port, --host and --base",
);
await refuses(
  "unknown command",
  ["serve"],
  {},
  2,
  "unknown command serve",
  toolBin,
);

const installed = workspaceCopy("installed");
mkdirSync(join(installed, "node_modules"));
await refuses(
  "own node_modules without astro",
  [],
  { BUILD_WORKSPACE_DIRECTORY: installed },
  1,
  "astro isn't in the consumer's node_modules",
);
if (lstatSync(join(installed, "node_modules")).isSymbolicLink()) {
  failures.push("own node_modules: the launcher replaced a real directory");
}

// What `bazel clean` leaves behind: a link into an output base that's gone.
const nodeModules = join(workspace, "node_modules");
symlinkSync(join(process.env.TEST_TMPDIR, "gone"), nodeModules, "junction");

const port = await new Promise((resolve) => {
  const probe = createServer();
  probe.listen(0, "127.0.0.1", () => {
    const { port: free } = probe.address();
    probe.close(() => resolve(free));
  });
});

// Both argument forms: --port=N and --base B.
const base = "/docs/";
const { child, exited } = start([`--port=${port}`, "--base", base], {
  BUILD_WORKSPACE_DIRECTORY: workspace,
});
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
child.kill("SIGTERM");
const result = await Promise.race([
  exited,
  new Promise((resolve) =>
    setTimeout(() => resolve({ code: "timeout" }), 15_000),
  ),
]);
if (status !== 200 || result.code !== 0) {
  failures.push(
    `server: ${url} answered ${status}; the server exited with ${result.code}`,
  );
  child.kill("SIGKILL");
}
if (!existsSync(join(nodeModules, "astro", "package.json"))) {
  failures.push("server: the dangling node_modules link wasn't replaced");
}

if (failures.length > 0) {
  console.error(`dev_test:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(
  `dev_test: the refusals hold, and ${url} answered 200 and the server exited 0 on SIGTERM`,
);
