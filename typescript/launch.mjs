// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs one of this module's pinned tools in the current directory, a check's
// copy of the consumer's tree. First it links into the tree's node_modules
// the consumer's packages (TBHB_NODE_MODULES, from the runfiles), then each
// pinned package this check's launcher carries where the consumer has no
// package of that name. Every link points at a package's real path, so its
// dependencies resolve from its own store. The consumer's configs and
// sources then import `vitest`, `typescript-eslint` and the rest, and tsc
// sees their types, without listing them as dependencies.
//
// pnpm-audit-workspace is the exception: it audits the `bazel run`
// workspace's own lock and links nothing.
//
// Usage: launch.mjs <tool> [args...]

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  symlinkSync,
} from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pinned = Object.keys(
  JSON.parse(readFileSync(join(here, "package.json"), "utf8")).dependencies,
);

// Pinned packages whose consumer copy, at another version, would split one
// tool into two instances: the test runners load the consumer's copy of
// these through its imports while running their own.
const MUST_MATCH =
  /^(vitest|@vitest\/.*|@stryker-mutator\/.*|@cloudflare\/vitest-plugin)$/;

function pinnedDir(name) {
  const dir = join(here, "node_modules", name);
  return existsSync(dir) ? realpathSync(dir) : null;
}

function version(dir) {
  return JSON.parse(readFileSync(join(dir, "package.json"), "utf8")).version;
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
  const mismatches = [];
  for (const rel of consumerDirs) {
    const dir = join(runfiles, workspace, rel);
    // A package.json without dependencies links no package, so its tree has
    // no directory. A label naming no such tree fails in checks.bzl or in
    // Bazel's analysis, before this runs.
    if (!existsSync(dir)) {
      continue;
    }
    for (const name of packagesIn(dir)) {
      const source = realpathSync(join(dir, name));
      const target = MUST_MATCH.test(name) ? pinnedDir(name) : null;
      if (target !== null) {
        // Even at the same version, the consumer's copy would load as a
        // second instance from another store, so the pinned one is linked.
        if (version(source) !== version(target)) {
          mismatches.push(
            `${name} ${version(source)} (this module pins ${version(target)})`,
          );
        }
        continue;
      }
      const path = join(tree, name);
      if (!existsSync(path)) {
        link(source, path);
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
  if (mismatches.length > 0) {
    console.error(
      `launch.mjs: the consumer's node_modules has its own ${mismatches.join(", ")}. ` +
        "Remove it from the consumer's package.json: this module supplies it.",
    );
    process.exit(1);
  }
}

// The wrangler configs in the tree, outside node_modules and dot
// directories.
function wranglerConfigs(dir) {
  const found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") {
      continue;
    }
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      found.push(...wranglerConfigs(path));
    } else if (/^wrangler\.(json|jsonc|toml)$/.test(entry.name)) {
      found.push(path);
    }
  }
  return found;
}

// workerd refuses a Worker whose compatibility date is newer than its own,
// and inside Bazel the test then hangs until its timeout instead of
// failing. Each wrangler config's dates must be no newer than the pinned
// workerd's, which the plugin reaches through miniflare.
async function checkCompatibilityDates() {
  const plugin = pinnedDir("@cloudflare/vitest-plugin");
  const miniflare = createRequire(join(plugin, "package.json")).resolve(
    "miniflare",
  );
  const workerd = createRequire(miniflare).resolve("workerd");
  const { compatibilityDate, version: workerdVersion } = await import(
    pathToFileURL(workerd).href
  );
  const late = [];
  for (const file of wranglerConfigs(process.cwd())) {
    const text = readFileSync(file, "utf8");
    for (const [, date] of text.matchAll(
      /compatibility_date["']?\s*[:=]\s*["'](\d{4}-\d{2}-\d{2})["']/g,
    )) {
      if (date > compatibilityDate) {
        // Forward slashes on every OS, so the message reads the same.
        late.push(
          `${relative(process.cwd(), file).split(sep).join("/")} (${date})`,
        );
      }
    }
  }
  if (late.length > 0) {
    console.error(
      `launch.mjs: the pinned workerd ${workerdVersion} supports compatibility dates up to ${compatibilityDate}, ` +
        `but ${late.join(", ")} asks for a later one. Set compatibility_date to ${compatibilityDate} or earlier, ` +
        "or wait for this module's next workerd.",
    );
    process.exit(1);
  }
}

async function runBin(name, bin, args) {
  const path = join(pinnedDir(name), bin);
  process.argv = [process.argv[0], path, ...args];
  await import(pathToFileURL(path).href);
}

async function eslint(args) {
  if (args.length > 0) {
    throw new Error(
      `launch.mjs: eslint takes no arguments, got ${args.join(" ")}`,
    );
  }
  const { ESLint } = await import(
    pathToFileURL(join(pinnedDir("eslint"), "lib", "api.js")).href
  );
  const linter = new ESLint({ errorOnUnmatchedPattern: true });
  const results = await linter.lintFiles(["."]);
  const report = await (await linter.loadFormatter("stylish")).format(results);
  if (report) {
    process.stdout.write(report);
  }
  const problems = results.reduce(
    (sum, r) => sum + r.errorCount + r.warningCount,
    0,
  );
  console.log(`eslint: linted ${results.length} files, ${problems} problems`);
  process.exitCode = problems === 0 ? 0 : 1;
}

async function vitest(args) {
  let coverage = false;
  let workers = false;
  let config;
  for (const arg of args) {
    if (arg === "--coverage") {
      coverage = true;
    } else if (arg === "--workers") {
      workers = true;
    } else if (arg.startsWith("--config=")) {
      config = arg.slice("--config=".length);
    } else {
      throw new Error(`launch.mjs: unknown vitest argument ${arg}`);
    }
  }
  if (workers) {
    await checkCompatibilityDates();
  }
  const { startVitest } = await import(
    pathToFileURL(join(pinnedDir("vitest"), "dist", "node.js")).href
  );
  const options = { run: true, watch: false, coverage: { enabled: coverage } };
  // V8 coverage can't see into workerd, and a Workers check links only
  // Istanbul; without this, Vitest would report a missing package instead.
  const istanbulOnly = {
    name: "tbhb-workers-coverage",
    configureVitest({ vitest: ctx }) {
      const provider = ctx.config.coverage.provider ?? "v8";
      if (coverage && provider !== "istanbul") {
        throw new Error(
          `launch.mjs: a workers check needs test.coverage.provider "istanbul" in the Vitest config, not "${provider}"`,
        );
      }
    },
  };
  const ctx = await startVitest(
    "test",
    [],
    config ? { ...options, config } : options,
    workers ? { plugins: [istanbulOnly] } : undefined,
  );
  const files = ctx?.state.getFiles() ?? [];
  // Tests that ran: skipped and todo tests prove nothing.
  const ran = files
    .flatMap(function collect(task) {
      return task.tasks ? task.tasks.flatMap(collect) : [task];
    })
    .filter(
      (task) =>
        task.mode === "run" && ["pass", "fail"].includes(task.result?.state),
    );
  console.log(`vitest: ran ${ran.length} tests in ${files.length} files`);
  await ctx?.close();
  if (!ctx || ran.length === 0) {
    process.exitCode = 1;
  }
  // When the Workers runtime fails to start, @cloudflare/vitest-plugin
  // drops its Miniflare without disposing it, and the Miniflare's loopback
  // server would keep node running until the test timeout. (Vitest's own
  // CLI forces an exit too, after its teardown timeout.)
  process.exit();
}

const [command, ...args] = process.argv.slice(2);
// pnpm-audit-workspace is the `bazel run //:pnpm_audit` form.
const tool = command === "pnpm-audit-workspace" ? "pnpm-audit" : command;
if (command === "pnpm-audit-workspace") {
  process.chdir(process.env.BUILD_WORKSPACE_DIRECTORY ?? process.cwd());
} else {
  linkPackages();
}
switch (tool) {
  case "biome":
    await runBin("@biomejs/biome", "bin/biome", args);
    break;
  case "depcruise":
    await runBin("dependency-cruiser", "bin/dependency-cruiser.mjs", args);
    break;
  case "eslint":
    await eslint(args);
    break;
  case "knip":
    await runBin("knip", "bin/knip.js", [
      ...args,
      "--reporter",
      "symbols",
      "--reporter",
      join(here, "knip_counter.mjs"),
    ]);
    break;
  case "pnpm-audit":
    await runBin("pnpm", "bin/pnpm.mjs", ["audit", ...args]);
    break;
  case "stryker":
    if (args[0] === "--workers") {
      args.shift();
      await checkCompatibilityDates();
    }
    await runBin("@stryker-mutator/core", "bin/stryker.js", args);
    break;
  case "tsc":
    await runBin("typescript", "lib/tsc.js", args);
    break;
  case "vitest":
    await vitest(args);
    break;
  default:
    console.error(`launch.mjs: unknown tool ${tool}`);
    process.exitCode = 2;
}
