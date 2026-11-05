// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The launcher's resolve hooks in a process of their own, for `import`,
// which goes through the asynchronous loader hook, and for `require`,
// which goes through the in-thread one: a bare specifier that resolves only
// from a fallback parent comes from there, and one that resolves nowhere,
// or a relative one that misses, fails as it would without the hooks, with
// Node's own error for the original importer.

import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const hooks = process.env.TBHB_LAUNCHER_DATA.split(" ").find((path) =>
  path.endsWith("/resolve_hooks.mjs"),
);
const tmp = process.env.TEST_TMPDIR;

// A package only the fallback parent's node_modules holds.
const parent = join(tmp, "parent");
const pkg = join(parent, "node_modules", "fallback-only");
mkdirSync(pkg, { recursive: true });
writeFileSync(
  join(pkg, "package.json"),
  JSON.stringify({ name: "fallback-only", type: "module", exports: "./index.js" }),
);
writeFileSync(join(pkg, "index.js"), "export const found = 'fallback';\n");
const cjs = join(parent, "node_modules", "fallback-only-cjs");
mkdirSync(cjs, { recursive: true });
writeFileSync(
  join(cjs, "package.json"),
  JSON.stringify({ name: "fallback-only-cjs", main: "index.cjs" }),
);
writeFileSync(join(cjs, "index.cjs"), "exports.found = 'fallback';\n");

const project = join(tmp, "project");
mkdirSync(project, { recursive: true });
writeFileSync(
  join(project, "probe.mjs"),
  `import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { found } = await import("fallback-only");
const required = require("fallback-only-cjs").found;
const codes = [];
const at = (error) => error.code + (error.message.includes("probe.mjs") ? "@probe" : "");
for (const specifier of ["missing-everywhere", "./missing.mjs"]) {
  try {
    await import(specifier);
    codes.push("resolved");
  } catch (error) {
    codes.push(at(error));
  }
  try {
    require(specifier);
    codes.push("resolved");
  } catch (error) {
    codes.push(at(error));
  }
}
console.log(JSON.stringify({ found, required, codes }));
`,
);

const run = spawnSync(
  process.execPath,
  ["--import", pathToFileURL(join(runfiles, hooks)).href, join(project, "probe.mjs")],
  {
    encoding: "utf8",
    env: {
      ...process.env,
      TBHB_FALLBACK_PARENTS: JSON.stringify([
        pathToFileURL(join(tmp, "nowhere", "package.json")).href,
        pathToFileURL(join(parent, "package.json")).href,
      ]),
    },
  },
);
const want = JSON.stringify({
  found: "fallback",
  required: "fallback",
  codes: [
    "ERR_MODULE_NOT_FOUND@probe",
    "MODULE_NOT_FOUND@probe",
    "ERR_MODULE_NOT_FOUND@probe",
    "MODULE_NOT_FOUND@probe",
  ],
});
if (run.status !== 0 || run.stdout.trim() !== want) {
  console.error(
    `hooks_test: expected ${want}, got exit ${run.status}:\n${run.stdout}${run.stderr}`,
  );
  process.exit(1);
}
console.log("hooks_test: the fallback resolves, and misses fail as Node's own");
