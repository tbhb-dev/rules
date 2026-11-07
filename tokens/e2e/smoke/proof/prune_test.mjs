// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Every var() in tokens_css's output names a custom property the output
// declares, and the scales a kept scale aliases are kept with it.

import { readFileSync } from "node:fs";
import { join } from "node:path";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const css = readFileSync(join(runfiles, process.env.TBHB_CSS), "utf8");
const declared = new Set(
  [...css.matchAll(/^\s*(--[\w-]+):/gm)].map((m) => m[1]),
);
const used = new Set([...css.matchAll(/var\((--[\w-]+)\)/g)].map((m) => m[1]));

const failures = [];
for (const name of used) {
  if (!declared.has(name)) {
    failures.push(`var(${name}) dangles: nothing declares ${name}`);
  }
}
for (const name of [
  "--palette-brand-10",
  "--palette-red-10",
  "--palette-glow-9",
  "--palette-blue-9",
]) {
  if (!declared.has(name)) {
    failures.push(`${name} is missing`);
  }
}
if (declared.has("--palette-unused-9")) {
  failures.push("--palette-unused-9 is emitted, though nothing refers to it");
}
if (failures.length > 0) {
  console.error(`prune_test:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(`prune_test: ${used.size} var() references, all declared`);
