// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Serves a built Storybook from a base path, the way a Pages site serves it
// under /storybook/<framework>/, and opens its story in the pinned Chromium:
// the story must render its heading, and no request may fail.
//
// Usage: dist_test.mjs <dist dir> <base> <story id> <heading>

import { existsSync, readFileSync, statSync } from "node:fs";
import http from "node:http";
import { extname, join } from "node:path";
import { pathToFileURL } from "node:url";

const [dist, base, story, heading] = process.argv.slice(2);
const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const { browsersPath } = await import(
  pathToFileURL(join(runfiles, process.env.TBHB_PLAYWRIGHT_HELPER)).href
);
process.env.PLAYWRIGHT_BROWSERS_PATH = browsersPath(
  process.env.TBHB_PLAYWRIGHT_BROWSERS,
);

const TYPES = {
  ".css": "text/css",
  ".html": "text/html",
  ".js": "text/javascript",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
};

const server = http.createServer((req, res) => {
  const path = new URL(req.url, "http://localhost").pathname;
  if (!path.startsWith(base)) {
    res.writeHead(404);
    res.end();
    return;
  }
  let file = join(dist, decodeURIComponent(path.slice(base.length)));
  if (existsSync(file) && statSync(file).isDirectory()) {
    file = join(file, "index.html");
  }
  if (!existsSync(file)) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, {
    "content-type": TYPES[extname(file)] ?? "application/octet-stream",
  });
  res.end(readFileSync(file));
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;

const { chromium } = await import("playwright-core");
const browser = await chromium.launch({ headless: true });
const failures = [];
try {
  const page = await browser.newPage();
  page.on("response", (r) => {
    if (r.status() >= 400) {
      failures.push(`${r.status()} ${r.url()}`);
    }
  });
  page.on("requestfailed", (r) => failures.push(`failed ${r.url()}`));
  await page.goto(`${origin}${base}?path=/story/${story}`);
  const frame = page.frameLocator("#storybook-preview-iframe");
  const found = frame.getByRole("heading", { name: heading });
  await found.waitFor({ timeout: 60_000 });
} catch (error) {
  failures.push(String(error.message ?? error).split("\n")[0]);
} finally {
  await browser.close();
  server.close();
}
if (failures.length > 0) {
  console.error(`dist_test: ${base}:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(`dist_test: ${base} renders "${heading}" with no failed request`);
