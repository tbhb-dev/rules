// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The launch proof: playwright-core must be the release the pinned browsers
// belong to, and the pinned Chromium headless shell must start from the
// runfiles with nothing but PLAYWRIGHT_BROWSERS_PATH set, then load a page.

import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, relative } from "node:path";

const require = createRequire(import.meta.url);
const core = dirname(require.resolve("playwright-core/package.json"));
const { version } = JSON.parse(readFileSync(join(core, "package.json"), "utf8"));
const shell = JSON.parse(
  readFileSync(join(core, "browsers.json"), "utf8"),
).browsers.find((b) => b.name === "chromium-headless-shell");

const failures = [];
if (version !== process.env.TBHB_PLAYWRIGHT_VERSION) {
  failures.push(
    `playwright-core is ${version}, but the browsers belong to ${process.env.TBHB_PLAYWRIGHT_VERSION}`,
  );
}
if (shell === undefined) {
  failures.push(
    `playwright-core ${version}'s browsers.json has no chromium-headless-shell entry, but the pins hold revision ${process.env.TBHB_PLAYWRIGHT_REVISION}`,
  );
} else if (shell.revision !== process.env.TBHB_PLAYWRIGHT_REVISION) {
  failures.push(
    `playwright-core ${version} wants chromium-headless-shell revision ${shell.revision}, but the pins hold ${process.env.TBHB_PLAYWRIGHT_REVISION}`,
  );
}
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const pathFile = join(runfiles, process.env.TBHB_PLAYWRIGHT_BROWSERS);
const browsersPath = join(runfiles, readFileSync(pathFile, "utf8").trim());
if (!existsSync(browsersPath)) {
  // On Windows without --enable_runfiles there is no runfiles tree to find
  // the browsers in.
  console.error(
    `the pinned browsers aren't at ${browsersPath}; on Windows, build with --enable_runfiles`,
  );
  process.exit(1);
}

// The first file under a directory, depth first.
function firstFile(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isFile() || entry.isSymbolicLink()) {
      return path;
    }
    const found = firstFile(path);
    if (found !== undefined) {
      return found;
    }
  }
  return undefined;
}

// The runfiles tree links each file, not each directory, so the browsers'
// real directory comes from one file's real path. Under it the browser's
// path is far shorter: on Windows the runfiles path to the executable runs
// past MAX_PATH, and CreateProcess then fails with ENOENT although the file
// is there.
const sample = firstFile(browsersPath);
const real = realpathSync(sample);
const rel = relative(browsersPath, sample);
const realBrowsers = real.endsWith(rel)
  ? real.slice(0, real.length - rel.length - 1)
  : browsersPath;
process.env.PLAYWRIGHT_BROWSERS_PATH = realBrowsers;
console.log(
  `PLAYWRIGHT_BROWSERS_PATH=${realBrowsers} (${realBrowsers.length} characters)`,
);

const { chromium } = await import("playwright-core");
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("data:text/html,<title>tbhb-playwright-smoke</title>");
  const title = await page.title();
  if (title !== "tbhb-playwright-smoke") {
    console.error(`expected the page title tbhb-playwright-smoke, got ${title}`);
    process.exitCode = 1;
  } else {
    console.log(`launched Chromium ${browser.version()}: ${title}`);
  }
} finally {
  await browser.close();
}
