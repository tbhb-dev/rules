// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs the pinned wrangler under `bazel run`, in the consumer's package
// directory (TBHB_PACKAGE, relative to the workspace), so wrangler reads
// and writes the consumer's own files.
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const workspace = process.env.BUILD_WORKSPACE_DIRECTORY;
if (workspace === undefined) {
  console.error("run.mjs: run this with `bazel run`");
  process.exit(2);
}
process.chdir(join(workspace, process.env.TBHB_PACKAGE ?? ""));
// wrangler's bin runs only as Node's main script, so it gets a process of
// its own.
const bin = join(here, "node_modules", "wrangler", "bin", "wrangler.js");
// wrangler's home, config and logs go to a temporary directory, not into
// the consumer's package.
const scratch = mkdtempSync(join(tmpdir(), "wrangler-run-"));
const result = spawnSync(process.execPath, [bin, ...process.argv.slice(2)], {
  stdio: "inherit",
  env: {
    ...process.env,
    HOME: join(scratch, "home"),
    USERPROFILE: join(scratch, "home"),
    WRANGLER_LOG_PATH: join(scratch, "logs"),
    XDG_CONFIG_HOME: join(scratch, "config"),
  },
});
rmSync(scratch, { recursive: true, force: true });
process.exit(result.status ?? 1);
