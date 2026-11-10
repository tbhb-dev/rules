// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs Storybook for one framework over a consumer's project:
//
//   build <outDir> <manifest>  copies the manifest's files into a scratch
//                              project and writes a static Storybook to outDir
//   test                       runs every story as a test in the pinned
//                              Chromium, in a check's copy of the project
//   dev [--port N] [--host H] [--base B]
//                              serves the consumer's own sources in the
//                              `bazel run` workspace, under a base path
//
// The project gets a generated config directory, whose main config imports
// the consumer's (TBHB_CONFIG_DIR) and fixes the framework, adds the a11y
// and Vitest addons, and layers Vite resolution over it; its preview imports
// the consumer's and replaces its project-level a11y settings, so an a11y
// violation fails a story's test with axe's defaults whatever the
// consumer's preview says. A story or a component can still set its own
// `parameters.a11y` and `globals.a11y`. In build and test the directory is
// .tbhb-storybook in the scratch copy of the project; in dev it's a
// temporary directory of the run's own, outside the workspace.
//
// The generated directory's node_modules links this module's packages, so
// the generated config resolves them. In build and test, the project's own
// node_modules links them too, ahead of the consumer's packages, so one
// Storybook loads; the consumer's renderer libraries (react and react-dom,
// lit, astro) are linked after them. A package of either store that
// doesn't resolve from its importer is resolved again from the other, in
// Node (resolve_hooks.mjs) and in Vite (vite_layer.mjs).

import { spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pinned = Object.keys(
  JSON.parse(readFileSync(join(here, "package.json"), "utf8")).dependencies,
);
const GEN = ".tbhb-storybook";
const FRAMEWORK = process.env.TBHB_FRAMEWORK;
const RENDERERS = (process.env.TBHB_RENDERERS ?? "").split(",").filter(Boolean);
const CONFIG_DIR = process.env.TBHB_CONFIG_DIR ?? ".storybook";

function fail(message, code = 1) {
  console.error(`launch.mjs: ${message}`);
  process.exit(code);
}

function link(target, path) {
  mkdirSync(dirname(path), { recursive: true });
  // A junction needs no privilege on Windows; elsewhere the type is ignored.
  symlinkSync(target, path, "junction");
}

// The package directories of one npm_link_all_packages tree: `name` and
// `@scope/name`, skipping rules_js's own store and bin entries.
function packagesIn(dir) {
  const names = [];
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".")) {
      continue;
    }
    if (entry.startsWith("@")) {
      for (const scoped of readdirSync(join(dir, entry))) {
        names.push(`${entry}/${scoped}`);
      }
    } else {
      names.push(entry);
    }
  }
  return names;
}

function linkPinned(nodeModules) {
  for (const name of pinned) {
    const path = join(nodeModules, name);
    if (!existsSync(path)) {
      link(realpathSync(join(here, "node_modules", name)), path);
    }
  }
}

// The consumer's npm_link_all_packages trees, from the runfiles.
function consumerTrees() {
  const runfiles =
    process.env.TEST_SRCDIR ??
    process.env.RUNFILES_DIR ??
    process.env.JS_BINARY__RUNFILES;
  return (process.env.TBHB_NODE_MODULES ?? "")
    .split(";")
    .filter(Boolean)
    .map((rel) => join(runfiles, "_main", rel))
    .filter((dir) => existsSync(dir));
}

// This module's packages, then the consumer's where a name is free.
function linkProject(root) {
  const nodeModules = join(root, "node_modules");
  linkPinned(nodeModules);
  for (const dir of consumerTrees()) {
    for (const name of packagesIn(dir)) {
      const path = join(nodeModules, name);
      if (!existsSync(path)) {
        link(realpathSync(join(dir, name)), path);
      }
    }
  }
}

// A package directory found the way Node finds one, from the nearest
// node_modules at or above `dir`.
function findPackage(dir, name) {
  for (;;) {
    if (existsSync(join(dir, "node_modules", name, "package.json"))) {
      return true;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      return false;
    }
    dir = parent;
  }
}

function requireRenderers(root) {
  const missing = RENDERERS.filter((name) => !findPackage(root, name));
  if (missing.length > 0) {
    fail(
      `the ${FRAMEWORK} framework needs ${missing.join(", ")} from the consumer's node_modules. ` +
        "Add it to the project's package.json and pass its npm_link_all_packages target as node_modules.",
    );
  }
}

// The consumer's config file `name` (main or preview), whatever its
// extension.
function configFile(root, name) {
  const dir = join(root, CONFIG_DIR);
  for (const ext of ["ts", "mts", "tsx", "js", "mjs", "jsx"]) {
    const path = join(dir, `${name}.${ext}`);
    if (existsSync(path)) {
      return path;
    }
  }
  return null;
}

// Options a framework needs because the config directory is generated: the
// astro framework finds astro, and the project's astro.config, from the
// config directory's parent unless told the project's root.
function frameworkDefaults(root) {
  return FRAMEWORK === "astro" ? { resolveFrom: root } : {};
}

function writeConfig(root, gen, { allow = [], ...options } = {}) {
  rmSync(gen, { recursive: true, force: true });
  linkPinned(join(gen, "node_modules"));
  const vite = {
    roots: [root, gen],
    framework: FRAMEWORK,
    stores: [...allow, ...stores(root, gen)],
    ...options,
  };
  const main = configFile(root, "main");
  if (main === null) {
    fail(`no main config in ${join(CONFIG_DIR, "main.*")}`);
  }
  const userDir = JSON.stringify(
    relative(gen, join(root, CONFIG_DIR)).split(sep).join("/"),
  );
  writeFileSync(
    join(gen, "main.mjs"),
    `import * as userModule from ${JSON.stringify(pathToFileURL(main).href)};
import { tbhbVite } from ${JSON.stringify(pathToFileURL(join(here, "vite_layer.mjs")).href)};

const user = userModule.default ?? userModule;
const OWN = ["@storybook/addon-a11y", "@storybook/addon-vitest"];
// Paths in the consumer's config are relative to its config directory.
const rebase = (path) => path.startsWith("/") ? path : \`\${${userDir}}/\${path}\`;
const rebaseEntry = (entry) =>
  typeof entry === "string"
    ? rebase(entry)
    : { ...entry, ...(entry.directory ? { directory: rebase(entry.directory) } : {}), ...(entry.from ? { from: rebase(entry.from) } : {}) };
const addonName = (addon) => (typeof addon === "string" ? addon : addon.name);

export default {
  ...user,
  stories: (user.stories ?? []).map(rebaseEntry),
  ...(user.staticDirs ? { staticDirs: user.staticDirs.map(rebaseEntry) } : {}),
  framework: { name: ${JSON.stringify(process.env.TBHB_FRAMEWORK_PACKAGE)}, options: { ...${JSON.stringify(frameworkDefaults(root))}, ...user.framework?.options } },
  addons: [...(user.addons ?? []).filter((addon) => !OWN.includes(addonName(addon))), ...OWN],
  // No project.json: it holds the build's time, so no two builds would match.
  core: { ...user.core, disableTelemetry: true, disableWhatsNewNotifications: true, disableProjectJson: true },
  async viteFinal(config, options) {
    const own = user.viteFinal ? await user.viteFinal(config, options) : config;
    return tbhbVite(own, ${JSON.stringify(vite)});
  },
};
`,
  );
  const preview = configFile(root, "preview");
  writeFileSync(
    join(gen, "preview.mjs"),
    `${preview === null ? "const user = {};" : `import * as user from ${JSON.stringify(pathToFileURL(preview).href)};`}

const { default: annotations = {}, ...named } = user;
const all = { ...named, ...annotations };

// Any a11y violation fails the story's test at the project level, whatever
// the consumer's preview says: its a11y parameters (test, disable, and axe's
// config, options and context) give way to axe's defaults at \`error\`, and
// its a11y globals can't make the check manual. A story or a component can
// still set its own.
const a11yGlobals = (globals = {}) => ({ ...globals, a11y: { ...globals.a11y, manual: false } });
export default {
  ...all,
  parameters: { ...all.parameters, a11y: { test: "error", disable: false } },
  initialGlobals: a11yGlobals(all.initialGlobals),
  ...(all.globals ? { globals: a11yGlobals(all.globals) } : {}),
};
`,
  );
  writeFileSync(
    join(gen, "vitest.config.mjs"),
    `import { storybookTest } from "@storybook/addon-vitest/vitest-plugin";
import { playwright } from "@vitest/browser-playwright";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [storybookTest({ configDir: ${JSON.stringify(gen)} })],
  // Vitest's browser runner imports setup files outside the project by their
  // bare file path, which Vite's fs checks refuse even when allowed. This
  // server is the test's own, headless and gone when the test ends.
  server: { fs: { strict: false } },
  test: {
    name: "storybook",
    root: ${JSON.stringify(root)},
    browser: { enabled: true, headless: true, provider: playwright(), instances: [{ browser: "chromium" }] },
  },
});
`,
  );
  return gen;
}

// The directories rules_js's stores sit in, for Vite's server.fs.allow:
// each package's real path, up to its store's node_modules.
function stores(root, gen) {
  const found = new Set();
  for (const dir of [join(root, "node_modules"), join(gen, "node_modules")]) {
    if (!existsSync(dir)) {
      continue;
    }
    for (const name of packagesIn(dir)) {
      const real = realpathSync(join(dir, name));
      const store = real.lastIndexOf(`${sep}.aspect_rules_js${sep}`);
      found.add(store === -1 ? real : real.slice(0, store));
    }
  }
  return [...found];
}

// Node resolution falls back from either store to the other, in this
// process and in Storybook's.
async function fallBackFrom(root, gen) {
  const parents = [
    pathToFileURL(join(root, "package.json")).href,
    pathToFileURL(join(gen, "package.json")).href,
  ];
  process.env.TBHB_FALLBACK_PARENTS = JSON.stringify(parents);
  const hooks = pathToFileURL(join(here, "resolve_hooks.mjs")).href;
  process.env.NODE_OPTIONS =
    `${process.env.NODE_OPTIONS ?? ""} --import ${hooks}`.trim();
  await import(hooks);
}

const STORYBOOK = join(
  here,
  "node_modules",
  "storybook",
  "dist",
  "bin",
  "core.js",
);

// Storybook runs in `cwd`, the generated directory, and keeps its cache
// there, not in a node_modules of the project, which may be a link into
// Bazel's output tree.
function storybook(args, cwd, projectRoot) {
  const child = spawn(process.execPath, [STORYBOOK, ...args], {
    cwd,
    env: {
      ...process.env,
      CACHE_DIR: join(cwd, "cache"),
      CI: "true",
      ...(projectRoot ? { STORYBOOK_PROJECT_ROOT: projectRoot } : {}),
      STORYBOOK_DISABLE_TELEMETRY: "1",
      // Storybook's dev server insists on naming a package manager, by a
      // lockfile or one on PATH; a sandbox has neither. It runs none here.
      npm_config_user_agent:
        process.env.npm_config_user_agent ?? "pnpm/12.16.1",
    },
    stdio: "inherit",
  });
  return {
    child,
    exited: new Promise((done) =>
      child.on("exit", (code, signal) => done({ code, signal })),
    ),
  };
}

async function build(outDir, manifest) {
  // js_binary runs in the output tree; the action's paths are relative to
  // the execution root.
  const execroot = process.env.JS_BINARY__EXECROOT ?? process.cwd();
  const root = mkdtempSync(join(tmpdir(), "storybook-"));
  for (const line of readFileSync(resolve(execroot, manifest), "utf8").split(
    "\n",
  )) {
    if (line === "") {
      continue;
    }
    const [src, dest] = line.split("\t");
    mkdirSync(dirname(join(root, dest)), { recursive: true });
    copyFileSync(resolve(execroot, src), join(root, dest));
  }
  outDir = resolve(execroot, outDir);
  try {
    linkProject(root);
    requireRenderers(root);
    const gen = join(root, GEN);
    await fallBackFrom(root, gen);
    writeConfig(root, gen);
    const { exited } = storybook(
      ["build", "--config-dir", gen, "--output-dir", outDir, "--quiet"],
      root,
    );
    const { code } = await exited;
    process.exitCode = code ?? 1;
    // Vite's manifest/cache is build metadata, not part of the static site.
    rmSync(join(outDir, ".vite"), { recursive: true, force: true });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

async function test() {
  const root = process.cwd();
  linkProject(root);
  requireRenderers(root);
  const gen = join(root, GEN);
  await fallBackFrom(root, gen);
  writeConfig(root, gen);
  const runfiles = process.env.TEST_SRCDIR ?? process.env.RUNFILES_DIR;
  const { browsersPath } = await import(
    pathToFileURL(join(runfiles, process.env.TBHB_PLAYWRIGHT_HELPER)).href
  );
  process.env.PLAYWRIGHT_BROWSERS_PATH = browsersPath(
    process.env.TBHB_PLAYWRIGHT_BROWSERS,
  );
  const { startVitest } = await import(
    pathToFileURL(join(here, "node_modules", "vitest", "dist", "node.js")).href
  );
  const ctx = await startVitest("test", [], {
    run: true,
    watch: false,
    config: join(gen, "vitest.config.mjs"),
    root,
  });
  const files = ctx.state.getFiles();
  // Stories that ran: skipped and todo tests prove nothing.
  const ran = files
    .flatMap(function collect(task) {
      return task.tasks ? task.tasks.flatMap(collect) : [task];
    })
    .filter(
      (task) =>
        task.mode === "run" && ["pass", "fail"].includes(task.result?.state),
    );
  console.log(
    `storybook test: ran ${ran.length} stories in ${files.length} files`,
  );
  await ctx.close();
  if (ran.length === 0) {
    process.exitCode = 1;
  }
  process.exit();
}

// The file that marks a workspace node_modules directory as this launcher's.
const LINKS_MARKER = ".tbhb-storybook-links";

// The consumer's node_modules for `dev`: a directory, beside the package
// that declared its npm_link_all_packages tree, linking each of the tree's
// packages to its real directory, where Node finds them. Not a link to the
// tree itself: a tree in a subpackage links its packages relatively into
// the root package's store, which Node doesn't follow from a sandboxed
// test's runfiles.
//
// A directory of the consumer's own there (a local `pnpm install`), or a
// link of theirs, is left alone. This launcher's directory, marked by
// LINKS_MARKER, is made anew each run, so links left dangling by `bazel
// clean` or an output base change go; so is a link into Bazel's output tree
// or a dangling one, which earlier versions made.
function linkWorkspaceNodeModules(workspace) {
  const runfiles = process.env.RUNFILES_DIR ?? process.env.JS_BINARY__RUNFILES;
  const rel = process.env.TBHB_NODE_MODULES;
  const source = join(runfiles, "_main", rel);
  const path = join(workspace, rel);
  let existing = null;
  try {
    existing = lstatSync(path);
  } catch {
    // Nothing there yet.
  }
  if (existing !== null) {
    const ours = existing.isSymbolicLink()
      ? !existsSync(path) ||
        readlinkSync(path).includes(`${sep}bazel-out${sep}`)
      : existsSync(join(path, LINKS_MARKER));
    if (!ours) {
      return;
    }
    // Removes the links, not what they point to.
    rmSync(path, { recursive: true, force: true });
  }
  // A package.json without dependencies links no package, so its tree has
  // no directory.
  if (!existsSync(source)) {
    return;
  }
  mkdirSync(path, { recursive: true });
  writeFileSync(
    join(path, LINKS_MARKER),
    "storybook_dev's links to the consumer's npm_link_all_packages tree; it remakes this directory each run.\n",
  );
  for (const name of packagesIn(source)) {
    link(realpathSync(join(source, name)), join(path, name));
  }
}

function devOptions(args) {
  const options = {
    port: process.env.STORYBOOK_PORT ?? "6006",
    host: process.env.STORYBOOK_HOST ?? "127.0.0.1",
    base: process.env.STORYBOOK_BASE ?? "/",
  };
  // `--port 6006` and `--port=6006` both work, and the same for --host and
  // --base.
  for (let i = 0; i < args.length; i += 1) {
    const match = /^--(port|host|base)(?:=(.*))?$/.exec(args[i]);
    const value = match?.[2] ?? args[i + 1];
    if (!match || value === undefined) {
      fail(
        `dev takes --port, --host and --base, each with a value, got ${args[i]}`,
        2,
      );
    }
    if (match[2] === undefined) {
      i += 1;
    }
    options[match[1]] = value;
  }
  if (!/^[0-9]+$/.test(options.port) || Number(options.port) > 65535) {
    fail(`dev takes a port from 0 to 65535, got ${options.port}`, 2);
  }
  // The base is a directory: it starts and ends with a slash.
  options.base = `/${options.base.replace(/^\/+|\/+$/g, "")}/`.replace(
    /^\/\/$/,
    "/",
  );
  return options;
}

function freePort() {
  return new Promise((done) => {
    const probe = net.createServer();
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => done(port));
    });
  });
}

// Storybook's manager and preview open their channel socket at an absolute
// /storybook-server-channel; served under a base, it moves under the base
// too, so two Storybooks behind one port don't share a path.
const CHANNEL = '"/storybook-server-channel"';

// Serves Storybook's dev server, on `target`, under `base`.
// Storybook's own routes sit at its root, so the base is stripped; Vite's
// HMR socket sits under the base, so that upgrade passes as it is.
function proxy({ base }, target) {
  const strip = (url) =>
    url.startsWith(base) ? `/${url.slice(base.length)}` : null;
  const server = http.createServer((req, res) => {
    const [pathname, query] = req.url.split(/(?=\?)/);
    if (`${pathname}/` === base) {
      res.writeHead(308, { location: `${base}${query ?? ""}` });
      res.end();
      return;
    }
    const path = strip(req.url);
    if (path === null) {
      res.writeHead(404);
      res.end(`not under ${base}`);
      return;
    }
    const upstream = http.request(
      {
        host: "127.0.0.1",
        port: target,
        path,
        method: req.method,
        headers: { ...req.headers, "accept-encoding": "identity" },
      },
      (up) => {
        // Storybook going away mid-response, as it does on a stop.
        up.on("error", () => res.destroy());
        if (!/javascript/.test(up.headers["content-type"] ?? "")) {
          res.writeHead(up.statusCode, up.headers);
          up.pipe(res);
          return;
        }
        const chunks = [];
        up.on("data", (chunk) => chunks.push(chunk));
        up.on("end", () => {
          const body = Buffer.concat(chunks)
            .toString("utf8")
            .replaceAll(
              CHANNEL,
              JSON.stringify(`${base}storybook-server-channel`),
            );
          const headers = { ...up.headers };
          delete headers["content-length"];
          delete headers.etag;
          res.writeHead(up.statusCode, headers);
          res.end(body);
        });
      },
    );
    // Storybook not listening yet: the caller retries. Once a response has
    // started, it can only be cut off.
    upstream.on("error", () => {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      res.writeHead(502);
      res.end("Storybook isn't up yet");
    });
    req.pipe(upstream);
  });
  server.on("upgrade", (req, socket, head) => {
    const hmr = (req.headers["sec-websocket-protocol"] ?? "").includes(
      "vite-hmr",
    );
    const stripped = strip(req.url);
    if (stripped === null) {
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      return;
    }
    const path = hmr ? req.url : stripped;
    const up = net.connect(target, "127.0.0.1", () => {
      const headers = Object.entries(req.headers)
        .map(([key, value]) => `${key}: ${value}`)
        .join("\r\n");
      up.write(`${req.method} ${path} HTTP/1.1\r\n${headers}\r\n\r\n`);
      up.write(head);
      socket.pipe(up).pipe(socket);
    });
    up.on("error", () => socket.destroy());
    socket.on("error", () => up.destroy());
  });
  return server;
}

function listen(server, { host, port }) {
  return new Promise((done) => {
    server.once("error", (error) =>
      fail(`dev can't listen on ${host}:${port}: ${error.code}`),
    );
    server.listen(Number(port), host, done);
  });
}

async function dev(args) {
  const options = devOptions(args);
  const workspace = process.env.BUILD_WORKSPACE_DIRECTORY;
  if (!workspace) {
    fail("dev runs under `bazel run`, which sets BUILD_WORKSPACE_DIRECTORY");
  }
  linkWorkspaceNodeModules(workspace);
  const root = join(workspace, process.env.TBHB_PACKAGE ?? "");
  requireRenderers(root);
  // The run's own generated directory, outside the workspace, so two runs
  // don't share one and nothing of it lands in the consumer's tree. It sits
  // in a private directory of its own: Storybook makes the config
  // directory's parent Vite's root, which Vite watches whole, so a parent
  // shared with other programs, as the temp directory is, would reload the
  // server on every file they write.
  const run = realpathSync(mkdtempSync(join(tmpdir(), "tbhb-storybook-")));
  const gen = join(run, "config");
  const cleanUp = () => rmSync(run, { recursive: true, force: true });
  process.on("exit", cleanUp);
  await fallBackFrom(root, gen);
  writeConfig(root, gen, {
    allow: [workspace],
    base: options.base,
    clientPort: Number(options.port),
  });
  const target = await freePort();
  // Bound before Storybook starts, so a port in use fails with nothing to
  // stop.
  const server = proxy(options, target);
  await listen(server, options);
  const { child, exited } = storybook(
    [
      "dev",
      "--config-dir",
      gen,
      "--port",
      String(target),
      "--host",
      "127.0.0.1",
      "--exact-port",
      "--ci",
      "--no-open",
      "--quiet",
    ],
    // Storybook checks a community framework by resolving it from its
    // working directory, which the generated directory's links satisfy; the
    // workspace's node_modules has only the consumer's packages. Its project
    // root stays the workspace.
    gen,
    workspace,
  );
  console.log(
    `storybook dev: serving ${FRAMEWORK} at http://${options.host}:${options.port}${options.base}`,
  );
  // A stop requested by SIGINT or SIGTERM exits 0, however Storybook ends:
  // Ctrl-C under `bazel run` signals the whole process group, so Storybook
  // can exit on its own SIGINT before this process handles its own.
  let stopping = false;
  const stop = () => {
    stopping = true;
    server.close();
    child.kill("SIGTERM");
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  const { code, signal } = await exited;
  server.close();
  const stopped =
    stopping ||
    ["SIGINT", "SIGTERM"].includes(signal) ||
    [130, 143].includes(code);
  process.exit(stopped ? 0 : (code ?? 1));
}

// storybook_dev's binary names its command in the environment, so the
// server starts the same whether `bazel run` or another program runs it.
const argv = process.argv.slice(2);
if (process.env.TBHB_STORYBOOK_COMMAND) {
  argv.unshift(process.env.TBHB_STORYBOOK_COMMAND);
}
const [command, ...args] = argv;
switch (command) {
  case "build":
    await build(...args);
    break;
  case "test":
    await test();
    break;
  case "dev":
    await dev(args);
    break;
  default:
    fail(`unknown command ${command}`, 2);
}
