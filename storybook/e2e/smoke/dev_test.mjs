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
// at the base path, ignore other programs' files written beside it in its
// temp directory, redirect the base without its slash, refuse paths
// outside it, and exit 0 on SIGTERM.
//
// Usage: dev_test.mjs [--refusals] <dev binary> <launcher binary> <base> <file>...

import { spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { connect, createServer } from "node:net";
import { dirname, join } from "node:path";

const argv = process.argv.slice(2);
const refusals = argv[0] === "--refusals";
const [devBin, launcherBin, base, ...files] = refusals ? argv.slice(1) : argv;
const failures = [];
// Where the dev server links the consumer's tree, relative to the workspace.
const linked = process.env.TBHB_SMOKE_NODE_MODULES;

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
// A detached child leads its own process group, which a signal can then
// reach as a whole.
function start(args, env, bin = devBin, detached = false) {
  const child = spawn(bin, args, {
    detached,
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
  return { child, exited, output: () => output };
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
  if (lstatSync(join(installed, linked)).isSymbolicLink()) {
    failures.push("own node_modules: the launcher replaced a real directory");
  }

  // A link of the consumer's own, not into Bazel's output tree, stays.
  const ownLink = workspaceCopy("own-link");
  const elsewhere = join(process.env.TEST_TMPDIR, "elsewhere");
  mkdirSync(elsewhere);
  symlinkSync(elsewhere, join(ownLink, linked), "junction");
  await refuses(
    "own node_modules link without the renderer",
    [],
    { BUILD_WORKSPACE_DIRECTORY: ownLink },
    1,
    "framework needs",
  );
  if (readlinkSync(join(ownLink, linked)) !== elsewhere) {
    failures.push("own node_modules link: the launcher replaced it");
  }

  // Their own copy: a refusal past the arguments links node_modules.
  const ports = workspaceCopy("ports");
  await refuses(
    "a port past 65535",
    ["--port", "70000"],
    { BUILD_WORKSPACE_DIRECTORY: ports },
    2,
    "dev takes a port from 0 to 65535, got 70000",
  );
  await refuses(
    "a port that isn't one",
    ["--port", "abc"],
    { BUILD_WORKSPACE_DIRECTORY: ports },
    2,
    "dev takes a port from 0 to 65535, got abc",
  );
  const taken = createServer();
  await new Promise((resolve) => taken.listen(0, "127.0.0.1", resolve));
  const takenPort = taken.address().port;
  // An earlier version's link into Bazel's output tree, which the first run
  // replaces with a directory of its own, which the second replaces in turn.
  const earlier = join(process.env.TEST_TMPDIR, "earlier", "bazel-out", "tree");
  mkdirSync(earlier, { recursive: true });
  symlinkSync(earlier, join(ports, linked), "junction");
  for (const run of ["first", "second"]) {
    await refuses(
      `a port in use, ${run} run`,
      ["--port", String(takenPort)],
      { BUILD_WORKSPACE_DIRECTORY: ports },
      1,
      `dev can't listen on 127.0.0.1:${takenPort}: EADDRINUSE`,
    );
    if (!existsSync(join(ports, linked, ".tbhb-storybook-links"))) {
      failures.push(`${run} run: ${linked} isn't the launcher's directory`);
    }
  }
  taken.close();

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

// What the proxy answers a socket upgrade at `path` with: "" when it closes
// the socket unanswered.
function upgrade(port, path) {
  return new Promise((resolve) => {
    const socket = connect(port, "127.0.0.1", () => {
      socket.write(
        `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\n` +
          "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
      );
    });
    let data = "";
    socket.on("data", (chunk) => {
      data += chunk;
    });
    socket.on("error", () => resolve(null));
    socket.on("close", () => resolve(data));
    setTimeout(() => {
      socket.destroy();
      resolve(null);
    }, 5_000);
  });
}

// With the refusals, what `bazel clean` leaves behind: a link into an
// output base that's gone. Without, a workspace with no node_modules yet.
const nodeModules = join(workspace, linked);
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

// The server's temp directory, shared with whatever else runs there, as a
// user's temp directory is.
const tmp = join(process.env.TEST_TMPDIR, "tmp");
mkdirSync(tmp);

// Both argument forms: --port=N and --base B. With the refusals, the stop
// is Ctrl-C's: SIGINT to the whole process group.
const { child, exited, output } = start(
  [`--port=${port}`, "--base", base],
  { BUILD_WORKSPACE_DIRECTORY: workspace, TMPDIR: tmp },
  devBin,
  refusals,
);
const url = `http://127.0.0.1:${port}${base}`;
const deadline = Date.now() + 120_000;
let status = 0;
let iframe = 0;
let starting = null;
while (Date.now() < deadline) {
  try {
    status = (await fetch(url)).status;
    if (status === 502 && starting === null) {
      starting = (await upgrade(port, `${base}storybook-server-channel`)) === "";
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
// Another program's files in the temp directory, beside the server's own:
// the server mustn't watch them, so it neither reloads nor restarts, and
// still serves.
const before = output().length;
const other = join(tmp, "other-tool");
mkdirSync(join(other, "src"), { recursive: true });
writeFileSync(join(tmp, "tsconfig.json"), "{}\n");
writeFileSync(join(other, "tsconfig.json"), "{}\n");
writeFileSync(join(other, "src", "index.ts"), "export const x = 1;\n");
writeFileSync(join(tmp, "note.txt"), "other\n");
await new Promise((resolve) => setTimeout(resolve, 5_000));
writeFileSync(join(other, "src", "index.ts"), "export const x = 2;\n");
await new Promise((resolve) => setTimeout(resolve, 5_000));
const watched = output()
  .slice(before)
  .split("\n")
  .filter((line) => /reload|restart|tsconfig/i.test(line));
const after = await fetch(`${url}iframe.html`).then(
  (res) => res.status,
  (error) => error.message,
);
const origin = `http://127.0.0.1:${port}`;
// Each answer, or the error that came instead.
async function answer(path) {
  try {
    const res = await fetch(`${origin}${path}`, { redirect: "manual" });
    return `${res.status} ${res.headers.get("location") ?? ""}`.trim();
  } catch (error) {
    return error.message;
  }
}
const bare = base.slice(0, -1);
const answers = {
  [bare]: [await answer(bare), `308 ${base}`],
  [`${bare}?path=/story`]: [await answer(`${bare}?path=/story`), `308 ${base}?path=/story`],
  "/elsewhere/": [await answer("/elsewhere/"), "404"],
};
const outsideSocket = await upgrade(port, "/elsewhere/");
const signal = refusals ? "SIGINT" : "SIGTERM";
if (refusals) {
  process.kill(-child.pid, signal);
} else {
  child.kill(signal);
}
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
if (watched.length > 0) {
  failures.push(
    `server: files beside it in the temp directory were watched:\n    ${watched.slice(0, 5).join("\n    ")}`,
  );
}
if (after !== 200) {
  failures.push(`server: iframe.html answered ${after} after the temp directory changed`);
}
if (starting !== true) {
  failures.push(
    starting === null
      ? "server: never answered 502 while Storybook started"
      : "server: a socket opened while Storybook started wasn't closed unanswered",
  );
}
for (const [path, [got, want]] of Object.entries(answers)) {
  if (got !== want) {
    failures.push(`server: ${path} answered ${got}, not ${want}`);
  }
}
if (!outsideSocket?.startsWith("HTTP/1.1 404")) {
  failures.push(`server: a socket at /elsewhere/ got ${JSON.stringify(outsideSocket)}, not a 404`);
}
// A tree with no packages links nothing.
const empty = process.env.TBHB_SMOKE_EMPTY_TREE === "1";
if (existsSync(join(nodeModules, ".tbhb-storybook-links")) === empty) {
  failures.push(
    empty
      ? `server: ${linked} was made for a tree with no packages`
      : `server: ${linked} wasn't linked to the built tree`,
  );
}
// The generated config lives outside the workspace.
const pkg = dirname(dirname(files.find((file) => file.endsWith(".storybook/main.ts"))));
if (existsSync(join(workspace, pkg, ".tbhb-storybook"))) {
  failures.push("server: the generated config landed in the workspace");
}

if (failures.length > 0) {
  console.error(`dev_test:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(
  `dev_test: ${refusals ? "the refusals hold, and " : ""}${url} answered 502 while starting, then 200, and the server exited 0 on ${signal}`,
);
