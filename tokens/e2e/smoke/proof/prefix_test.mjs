// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// With a prefix, every custom property tokens_css declares, and every
// var() it writes, carries it.

import { readFileSync } from "node:fs";
import { join } from "node:path";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const css = readFileSync(join(runfiles, process.env.TBHB_CSS), "utf8");
const declared = [...css.matchAll(/^\s*(--[\w-]+):/gm)].map((m) => m[1]);
const used = [...css.matchAll(/var\((--[\w-]+)\)/g)].map((m) => m[1]);

const failures = [];
if (declared.length === 0 || used.length === 0) {
  failures.push("expected declarations and var()s");
}
for (const name of new Set([...declared, ...used])) {
  if (!name.startsWith("--smoke-")) {
    failures.push(`${name} lacks the prefix --smoke-`);
  }
}
if (!declared.includes("--smoke-palette-brand-10")) {
  failures.push("--smoke-palette-brand-10 is missing");
}
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
