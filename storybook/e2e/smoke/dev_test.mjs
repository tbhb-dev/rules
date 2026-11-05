// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs a storybook_dev target over a copy of its Storybook, the way `bazel
// run` would in a workspace.
//
// With --refusals, first the refusals: no BUILD_WORKSPACE_DIRECTORY, a bad
// argument, an argument without a value, an unknown command (through the
// build's launcher, whose binary names no command of its own), and a
// workspace whose own node_modules directory lacks the renderer, which the
// launcher must leave alone; and a main config that throws, whose failure
// Storybook's dev server and its build must each pass on. Then the server,
// in a workspace with no node_modules or, with --refusals, a dangling link
// there, as `bazel clean` leaves one: it must link the built tree, answer
// 502 until Storybook is up and refuse a socket meanwhile, then answer 200
// at the base path, redirect the base without its slash, refuse paths
// outside it, and exit 0 on SIGTERM.
//
// Usage: dev_test.mjs [--refusals] <dev binary> <launcher binary> <base> <file>...

import { spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { connect, createServer } from "node:net";
import { dirname, join } from "node:path";

const argv = process.argv.slice(2);
const refusals = argv[0] === "--refusals";
const [devBin, launcherBin, base, ...files] = refusals ? argv.slice(1) : argv;
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

// Storybook reports some failures on stdout, so a refusal's message is
// looked for in both streams.
function start(args, env, bin = devBin) {
  const child = spawn(bin, args, {
    env: { ...process.env, BAZEL_BINDIR: ".", ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  for (const [stream, sink] of [
    [child.stdout, process.stdout],
    [child.stderr, process.stderr],
  ]) {
    stream.on("data", (chunk) => {
      output += chunk;
      sink.write(chunk);
    });
  }
  const exited = new Promise((resolve) =>
    child.on("exit", (code) => resolve({ code, output })),
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
  if (result.code !== code || !result.output.includes(message)) {
    failures.push(
      `${label}: expected exit ${code} with "${message}", got exit ${result.code}`,
    );
  }
}

const workspace = workspaceCopy("workspace");

if (refusals) {
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
    launcherBin,
  );
  const installed = workspaceCopy("installed");
  mkdirSync(join(installed, "node_modules"));
  await refuses(
    "own node_modules without the renderer",
    [],
    { BUILD_WORKSPACE_DIRECTORY: installed },
    1,
    "framework needs",
  );
  if (lstatSync(join(installed, "node_modules")).isSymbolicLink()) {
    failures.push("own node_modules: the launcher replaced a real directory");
  }

  // A main config that throws: Storybook fails, and so must dev and build.
  const broken = workspaceCopy("broken");
  const main = files.find((file) => file.endsWith(".storybook/main.ts"));
  writeFileSync(join(broken, main), 'throw new Error("planted main failure");\n');
  await refuses(
    "dev, Storybook failing",
    [],
    { BUILD_WORKSPACE_DIRECTORY: broken },
    1,
    "planted main failure",
  );
  const pkg = dirname(dirname(main));
  const manifest = join(process.env.TEST_TMPDIR, "broken.manifest");
  writeFileSync(
    manifest,
    files
      .map((file) => `${join(broken, file)}\t${file.slice(pkg.length + 1)}\n`)
      .join(""),
  );
  await refuses(
    "build, Storybook failing",
    ["build", join(process.env.TEST_TMPDIR, "broken-dist"), manifest],
    {},
    1,
    "planted main failure",
    launcherBin,
  );
}

// Whether the proxy closes a socket it can't pass on, sending nothing.
function socketRefused(port) {
  return new Promise((resolve) => {
    const socket = connect(port, "127.0.0.1", () => {
      socket.write(
        `GET ${base}storybook-server-channel HTTP/1.1\r\nHost: 127.0.0.1\r\n` +
          "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
      );
    });
    let data = "";
    socket.on("data", (chunk) => {
      data += chunk;
    });
    socket.on("error", () => resolve(false));
    socket.on("close", () => resolve(data === ""));
    setTimeout(() => {
      socket.destroy();
      resolve(false);
    }, 5_000);
  });
}

// With the refusals, what `bazel clean` leaves behind: a link into an
// output base that's gone. Without, a workspace with no node_modules yet.
const nodeModules = join(workspace, "node_modules");
if (refusals) {
  symlinkSync(join(process.env.TEST_TMPDIR, "gone"), nodeModules, "junction");
}

const port = await new Promise((resolve) => {
  const probe = createServer();
  probe.listen(0, "127.0.0.1", () => {
    const { port: free } = probe.address();
    probe.close(() => resolve(free));
  });
});

// Both argument forms: --port=N and --base B.
const { child, exited } = start([`--port=${port}`, "--base", base], {
  BUILD_WORKSPACE_DIRECTORY: workspace,
});
const url = `http://127.0.0.1:${port}${base}`;
const deadline = Date.now() + 120_000;
let status = 0;
let iframe = 0;
let starting = null;
while (Date.now() < deadline) {
  try {
    status = (await fetch(url)).status;
    if (status === 502 && starting === null) {
      starting = await socketRefused(port);
    }
    iframe = (await fetch(`${url}iframe.html`)).status;
    if (status === 200 && iframe === 200) {
      break;
    }
  } catch {
    // Not listening yet.
  }
  await new Promise((resolve) => setTimeout(resolve, 500));
}
const origin = `http://127.0.0.1:${port}`;
const bare = await fetch(`${origin}${base.slice(0, -1)}`, { redirect: "manual" });
const outside = (await fetch(`${origin}/elsewhere/`)).status;
child.kill("SIGTERM");
const result = await Promise.race([
  exited,
  new Promise((resolve) =>
    setTimeout(() => resolve({ code: "timeout" }), 15_000),
  ),
]);
if (status !== 200 || iframe !== 200 || result.code !== 0) {
  failures.push(
    `server: ${url} answered ${status} (iframe.html ${iframe}); the server exited with ${result.code}`,
  );
  child.kill("SIGKILL");
}
if (starting !== true) {
  failures.push(
    starting === null
      ? "server: never answered 502 while Storybook started"
      : "server: a socket opened while Storybook started wasn't closed unanswered",
  );
}
if (bare.status !== 308 || bare.headers.get("location") !== base) {
  failures.push(`server: ${base.slice(0, -1)} answered ${bare.status}, not 308 to ${base}`);
}
if (outside !== 404) {
  failures.push(`server: /elsewhere/ answered ${outside}, not 404`);
}
if (!existsSync(join(nodeModules, ".aspect_rules_js"))) {
  failures.push("server: node_modules wasn't linked to the built tree");
}

if (failures.length > 0) {
  console.error(`dev_test:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(
  `dev_test: ${refusals ? "the refusals hold, and " : ""}${url} answered 502 while starting, then 200, and the server exited 0 on SIGTERM`,
);
