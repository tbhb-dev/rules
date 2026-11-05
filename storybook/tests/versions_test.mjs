// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// This module's playwright drives tbhb_rules_playwright's pinned browsers,
// which belong to one Playwright release: the two must agree.

import { readFileSync } from "node:fs";
import { join } from "node:path";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const pkgJson = process.env.TBHB_LAUNCHER_DATA.split(" ").find((path) =>
  path.endsWith("/package.json"),
);
const pkg = JSON.parse(readFileSync(join(runfiles, pkgJson), "utf8"));
const pinned = pkg.dependencies.playwright;
const want = process.env.TBHB_PLAYWRIGHT_VERSION;
if (pinned !== want) {
  console.error(
    `versions_test: package.json pins playwright ${pinned}; tbhb_rules_playwright's browsers are for ${want}. Move both together.`,
  );
  process.exit(1);
}
console.log(`versions_test: playwright ${pinned} matches the pinned browsers`);
