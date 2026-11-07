// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Loads tokens_css's output in the pinned Chromium headless shell and reads
// the computed --color-surface for each theme, data-mode and preferred
// color scheme, and in a nested subtree. The expected color is step 1 of
// the theme's neutral scale in the effective mode, built from the
// committed palette files, so the check doesn't share Terrazzo's output
// format.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const read = (path) => readFileSync(join(runfiles, path), "utf8");
const css = read(process.env.TBHB_CSS);

const NEUTRAL = { ocean: "gray", forest: "sand" };
const palettes = new Map(
  process.env.TBHB_PALETTES.split(" ").map((path) => {
    const [, scale, mode] = path.match(/([a-z]+)\.(light|dark)\.tokens\.json$/);
    return [`${scale}.${mode}`, JSON.parse(read(path)).palette[scale]];
  }),
);
function expected(theme, mode) {
  const scale = NEUTRAL[theme];
  const [l, c, h] = palettes.get(`${scale}.${mode}`)["1"].$value.components;
  return { css: `oklch(${l} ${c} ${h})`, name: `${scale} 1 ${mode}` };
}

// playwright-core must be the release the pinned browsers belong to.
const core = dirname(
  createRequire(import.meta.url).resolve("playwright-core/package.json"),
);
const { version } = JSON.parse(
  readFileSync(join(core, "package.json"), "utf8"),
);
if (version !== process.env.TBHB_PLAYWRIGHT_VERSION) {
  console.error(
    `browser_test: playwright-core is ${version}, but tbhb_rules_playwright's browsers belong to ${process.env.TBHB_PLAYWRIGHT_VERSION}; move package.json's pin to it`,
  );
  process.exit(1);
}

const { browsersPath } = await import(
  pathToFileURL(join(runfiles, process.env.TBHB_PLAYWRIGHT_HELPER)).href
);
process.env.PLAYWRIGHT_BROWSERS_PATH = browsersPath(
  process.env.TBHB_PLAYWRIGHT_BROWSERS,
);
const { chromium } = await import("playwright-core");

// The color an element's --color-surface computes to, and the color a
// literal computes to, both as the browser serializes a background-color.
async function surface(page, selector) {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel);
    el.style.backgroundColor = "var(--color-surface)";
    return getComputedStyle(el).backgroundColor;
  }, selector);
}
async function literal(page, color) {
  return page.evaluate((value) => {
    const probe = document.createElement("i");
    probe.style.backgroundColor = value;
    document.body.append(probe);
    const got = getComputedStyle(probe).backgroundColor;
    probe.remove();
    return got;
  }, color);
}

const failures = [];
let cells = 0;
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  for (const scheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme: scheme });
    for (const theme of [undefined, "ocean", "forest"]) {
      for (const mode of [undefined, "light", "dark"]) {
        const attrs = [
          theme ? `data-theme="${theme}"` : "",
          mode ? `data-mode="${mode}"` : "",
        ].join(" ");
        await page.setContent(
          `<html ${attrs}><head><style>${css}</style></head><body><main data-theme="forest" data-mode="dark"></main></body></html>`,
        );
        const want = expected(theme ?? "ocean", mode ?? scheme);
        const got = await surface(page, "html");
        const lit = await literal(page, want.css);
        cells += 1;
        if (got !== lit) {
          failures.push(
            `prefers ${scheme}, ${attrs || "no attributes"}: --color-surface is ${got}; expected ${want.name}, ${lit}`,
          );
        }
        // A subtree that carries both attributes switches on its own.
        const nested = await surface(page, "main");
        const nestedWant = expected("forest", "dark");
        const nestedLit = await literal(page, nestedWant.css);
        if (nested !== nestedLit) {
          failures.push(
            `prefers ${scheme}, ${attrs || "no attributes"}: a nested data-theme="forest" data-mode="dark" gets ${nested}; expected ${nestedWant.name}, ${nestedLit}`,
          );
        }
      }
    }
  }
} finally {
  await browser.close();
}

if (failures.length > 0) {
  console.error(`browser_test:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(
  `browser_test: --color-surface is right in ${cells} cells and their nested subtrees`,
);
