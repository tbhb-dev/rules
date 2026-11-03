// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// worker_bundle's tool: `wrangler deploy --dry-run --outdir <dir> ...`,
// then removes the README.md wrangler writes into <dir>, whose timestamp
// would make every build's output differ.
import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const outdir = args[args.indexOf("--outdir") + 1];
const here = dirname(fileURLToPath(import.meta.url));
const bin = join(here, "node_modules", "wrangler", "bin", "wrangler.js");
const result = spawnSync(process.execPath, [bin, ...args], {
  stdio: "inherit",
});
if (result.status !== 0) {
  console.error(
    `bundle: wrangler ${result.signal ? `stopped by ${result.signal}` : `exited ${result.status}`}`,
  );
  process.exit(1);
}
rmSync(join(outdir, "README.md"), { force: true });
