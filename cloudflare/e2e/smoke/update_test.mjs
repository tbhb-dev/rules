// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs worker_types_test's `.update` target on a copy of the Worker, as
// `bazel run` would in the consumer's work tree, and checks what it leaves.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

const runfiles = process.env.RUNFILES_DIR ?? process.env.JS_BINARY__RUNFILES;
const main = join(runfiles, process.env.TEST_WORKSPACE ?? "_main");
const types = "worker-configuration.d.ts";
const committed = readFileSync(join(main, types), "utf8");

// A fresh work tree with the Worker's files; `seed` is the types file's
// content, or null for none.
function update(name, seed) {
  const tree = join(process.env.TEST_TMPDIR, name);
  rmSync(tree, { recursive: true, force: true });
  mkdirSync(tree);
  for (const file of ["package.json", "src", "wrangler.jsonc"]) {
    cpSync(join(main, file), join(tree, file), { recursive: true });
  }
  if (seed !== null) {
    writeFileSync(join(tree, types), seed);
  }
  // The target's own args apply only under `bazel run`, so they're repeated.
  const args = ["types", "--config", "wrangler.jsonc", types];
  // On Windows the target is a .bat launcher, which Node starts only
  // through a shell; the args hold no characters cmd would reinterpret.
  const result = spawnSync(join(main, process.env.update), args, {
    encoding: "utf8",
    env: { ...process.env, BAZEL_BINDIR: ".", BUILD_WORKSPACE_DIRECTORY: tree },
    shell: process.platform === "win32",
  });
  return { tree, result };
}

const treeFiles = (tree) => readdirSync(tree).sort();

for (const [name, seed] of [
  ["an empty file", ""],
  ["a file of blank lines", "\n\n"],
  ["no file", null],
]) {
  test(`the update writes the types over ${name} and leaves no .wrangler`, () => {
    const { tree, result } = update("start", seed);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(
      readFileSync(join(tree, types), "utf8") === committed,
      "the types differ from the committed file",
    );
    assert.deepEqual(treeFiles(tree), [
      "package.json",
      "src",
      types,
      "wrangler.jsonc",
    ]);
  });
}

test("the update leaves a file that isn't Wrangler's as it was", () => {
  const mine = "export type Mine = string;\n";
  const { tree, result } = update("foreign", mine);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /A non-Wrangler worker-configuration\.d\.ts/);
  assert.equal(readFileSync(join(tree, types), "utf8"), mine);
  assert.ok(!treeFiles(tree).includes(".wrangler"));
});
