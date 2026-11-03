// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// worker_types_test's tool: regenerates a Worker's types with the pinned
// wrangler in the check's copy of the tree and compares the whole file.
// `wrangler types --check` reads only the file's header (the config hash and
// the workerd version), so an edited or stale body would pass it.
//
// Usage: check_types.mjs <config> <types> <update target>
import { spawnSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [config, types, update] = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
const bin = join(here, "node_modules", "wrangler", "bin", "wrangler.js");

const committed = readFileSync(types, "utf8");
// The tree is a scratch copy. wrangler skips writing a file whose header
// already matches, so the committed file goes first; wrangler then writes
// the same path, which its header names.
rmSync(types);
const result = spawnSync(
  process.execPath,
  [bin, "types", "--config", config, types],
  { stdio: ["ignore", "ignore", "inherit"] },
);
if (result.status !== 0) {
  console.error(
    `check_types: wrangler types ${result.signal ? `stopped by ${result.signal}` : `exited ${result.status}`}`,
  );
  process.exit(1);
}
const generated = readFileSync(types, "utf8");
if (generated !== committed) {
  const a = committed.split("\n");
  const b = generated.split("\n");
  let line = 0;
  while (line < a.length && a[line] === b[line]) {
    line += 1;
  }
  console.error(
    `check_types: ${types} differs from what wrangler types writes, first at line ${line + 1}:\n` +
      `  committed: ${a[line] ?? "(end of file)"}\n` +
      `  generated: ${b[line] ?? "(end of file)"}\n` +
      `Run \`bazel run ${update}\` and commit the result.`,
  );
  process.exit(1);
}
console.log(
  `check_types: ${types} matches, ${generated.split("\n").length} lines`,
);
