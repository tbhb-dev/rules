// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs the consumer's astro in the current directory: `check` in a check's
// copy of the consumer's tree, `build` in a build action's package
// directory.
//
// For `check`, it first links into the tree's node_modules the consumer's
// packages (TBHB_NODE_MODULES, from the runfiles), then each pinned package
// (@astrojs/check and TypeScript) where the consumer has none of that name.
// Every link points at a package's real path, so its dependencies resolve
// from its own store. astro then finds @astrojs/check as if the consumer had
// installed it. A build action has the consumer's node_modules beside its
// sources already and links nothing.
//
// astro is always the consumer's own dependency: this module doesn't pin
// it, so a project's build and check run the astro its lock names.
//
// `dev` runs astro's dev server on the consumer's own sources, in the
// `bazel run` workspace (BUILD_WORKSPACE_DIRECTORY), for a local preview.
//
// Usage: launch.mjs check [args...] | launch.mjs build <outDir> | launch.mjs dev [--port N] [--host H] [--base B]

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pinned = Object.keys(
  JSON.parse(readFileSync(join(here, "package.json"), "utf8")).dependencies,
);

function pinnedDir(name) {
  const dir = join(here, "node_modules", name);
  return existsSync(dir) ? realpathSync(dir) : null;
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

function linkPackages() {
  const tree = join(process.cwd(), "node_modules");
  const runfiles = process.env.TEST_SRCDIR ?? process.env.RUNFILES_DIR;
  const workspace = process.env.TEST_WORKSPACE ?? "_main";
  const consumerDirs = (process.env.TBHB_NODE_MODULES ?? "")
    .split(";")
    .filter(Boolean);
  for (const rel of consumerDirs) {
    const dir = join(runfiles, workspace, rel);
    // A package.json without dependencies links no package, so its tree
    // has no directory.
    if (!existsSync(dir)) {
      continue;
    }
    for (const name of packagesIn(dir)) {
      const path = join(tree, name);
      if (!existsSync(path)) {
        link(realpathSync(join(dir, name)), path);
      }
    }
  }
  for (const name of pinned) {
    const target = pinnedDir(name);
    const path = join(tree, name);
    if (target !== null && !existsSync(path)) {
      link(target, path);
    }
  }
}

// The .astro files in the tree, outside node_modules and dot directories.
function astroFiles(dir) {
  let count = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") {
      continue;
    }
    if (entry.isDirectory()) {
      count += astroFiles(join(dir, entry.name));
    } else if (entry.name.endsWith(".astro")) {
      count += 1;
    }
  }
  return count;
}

// The consumer's astro CLI, from the nearest node_modules at or above the
// current directory, the way Node resolves a package: a site in a
// subpackage finds the repository root's node_modules.
function astroDir() {
  let dir = process.cwd();
  for (;;) {
    const candidate = join(dir, "node_modules", "astro");
    if (existsSync(join(candidate, "package.json"))) {
      return candidate;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      return null;
    }
    dir = parent;
  }
}

// The consumer's astro package directory, or an error and exit 1.
function requireAstro() {
  const dir = astroDir();
  if (dir === null) {
    console.error(
      "launch.mjs: astro isn't in the consumer's node_modules. " +
        "Add astro to the project's package.json and pass its npm_link_all_packages target as node_modules.",
    );
    process.exit(1);
  }
  return realpathSync(dir);
}

// The consumer's node_modules for `dev`: the npm_link_all_packages tree in
// the runfiles, linked into the workspace where Node finds it, beside the
// package that declared it. A real directory there (a local `pnpm
// install`) is left alone. A link there, from an earlier run, is replaced:
// after `bazel clean` or an output base change it dangles.
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
  if (existing !== null && !existing.isSymbolicLink()) {
    return;
  }
  if (existing !== null) {
    unlinkSync(path);
  }
  // A package.json without dependencies links no package, so its tree has
  // no directory to link.
  if (existsSync(source)) {
    link(realpathSync(source), path);
  }
}

function devOptions(args) {
  const options = {
    port: process.env.ASTRO_PORT,
    host: process.env.ASTRO_HOST ?? "127.0.0.1",
    base: process.env.ASTRO_BASE,
  };
  // `--port 4321` and `--port=4321` both work, and the same for --host and
  // --base.
  for (let i = 0; i < args.length; i += 1) {
    const match = /^--(port|host|base)(?:=(.*))?$/.exec(args[i]);
    const value = match?.[2] ?? args[i + 1];
    // An empty value, as in `--port=`, is no value.
    if (!match || value === undefined || value === "") {
      console.error(
        `launch.mjs: dev takes --port, --host and --base, each with a value, got ${args[i]}`,
      );
      process.exit(2);
    }
    if (match[2] === undefined) {
      i += 1;
    }
    options[match[1]] = value;
  }
  return options;
}

async function dev(args) {
  const options = devOptions(args);
  const workspace = process.env.BUILD_WORKSPACE_DIRECTORY;
  if (!workspace) {
    console.error(
      "launch.mjs: dev runs under `bazel run`, which sets BUILD_WORKSPACE_DIRECTORY",
    );
    process.exit(1);
  }
  linkWorkspaceNodeModules(workspace);
  const root = join(workspace, process.env.TBHB_PACKAGE ?? "");
  process.chdir(root);
  const { dev: start } = await import(
    pathToFileURL(join(requireAstro(), "dist", "index.js")).href
  );
  // server.open false and no TTY: the server never opens a browser or
  // waits on a prompt.
  const server = await start({
    root,
    ...(options.base ? { base: options.base } : {}),
    server: {
      host: options.host,
      open: false,
      ...(options.port ? { port: Number(options.port) } : {}),
    },
  });
  let stopping = false;
  // Vite's own SIGTERM handler closes its server too, then exits with
  // `process.exitCode ??= 143`; setting the code first, before any await,
  // makes a requested stop exit 0 whichever handler finishes first.
  const stop = async () => {
    process.exitCode = 0;
    if (stopping) {
      return;
    }
    stopping = true;
    await server.stop();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

async function runAstro(args) {
  const bin = join(requireAstro(), "bin", "astro.mjs");
  process.argv = [process.argv[0], bin, ...args];
  await import(pathToFileURL(bin).href);
}

// astro_dev's binary names its command in the environment, so the server
// starts the same whether `bazel run` or another program runs the binary.
const argv = process.argv.slice(2);
if (process.env.TBHB_ASTRO_COMMAND) {
  argv.unshift(process.env.TBHB_ASTRO_COMMAND);
}
const [command, ...args] = argv;
switch (command) {
  case "check": {
    linkPackages();
    const files = astroFiles(process.cwd());
    if (files === 0) {
      console.error("astro check: the tree holds no .astro files");
      process.exit(1);
    }
    console.log(`astro check: ${files} .astro files in the tree`);
    // Warnings fail the check, as in the other tbhb_rules checks.
    await runAstro(["check", "--minimumFailingSeverity", "warning", ...args]);
    break;
  }
  case "build":
    await runAstro(["build", "--outDir", ...args]);
    break;
  case "dev":
    await dev(args);
    break;
  default:
    console.error(`launch.mjs: unknown command ${command}`);
    process.exitCode = 2;
}
