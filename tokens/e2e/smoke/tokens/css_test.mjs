// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Reads tokens_css's output as text: each top-level block, keyed by its
// selectors (an at-rule and the rule inside it joined by " / "), and the
// custom properties it declares.

import { readFileSync } from "node:fs";
import { join } from "node:path";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const css = readFileSync(join(runfiles, process.env.TBHB_CSS), "utf8");

const blocks = new Map();
for (const chunk of css.split(/\n\n/)) {
  const headers = [...chunk.matchAll(/^\s*(.+?) \{$/gm)].map((m) => m[1]);
  if (headers.length === 0) {
    continue;
  }
  const decls = new Map(
    [...chunk.matchAll(/^\s*(--[\w-]+): (.+);$/gm)].map((m) => [m[1], m[2]]),
  );
  blocks.set(headers.join(" / "), decls);
}

const failures = [];
function expect(ok, message) {
  if (!ok) {
    failures.push(message);
  }
}
function block(key) {
  const found = blocks.get(key);
  expect(found, `no block ${key}`);
  return found ?? new Map();
}
function declares(key, prop, value) {
  const got = block(key).get(prop);
  expect(got === value, `${key} declares ${prop}: ${got}; expected ${value}`);
}
function omits(key, prop) {
  expect(
    !block(key).has(prop),
    `${key} declares ${prop}, which doesn't vary there`,
  );
}

const DARK = "@media (prefers-color-scheme: dark)";
const GRAY1_LIGHT = "oklch(99.09% 0 0)";
const GRAY1_DARK = "oklch(17.8% 0 0)";

// The default contexts (ocean, light) at :root: every kept token.
declares(":root", "--color-surface", "var(--role-neutral-1)");
declares(":root", "--role-neutral-1", "var(--palette-gray-1)");
declares(":root", "--palette-gray-1", GRAY1_LIGHT);
declares(":root", "--space-1", "0.25rem");

// Each theme: its roles, and the semantic aliases over them, redeclared so
// a nested subtree resolves them against its own roles.
declares('[data-theme="ocean"]', "--role-neutral-1", "var(--palette-gray-1)");
declares('[data-theme="forest"]', "--role-neutral-1", "var(--palette-sand-1)");
declares('[data-theme="forest"]', "--role-accent-9", "var(--palette-grass-9)");
declares('[data-theme="forest"]', "--color-surface", "var(--role-neutral-1)");
omits('[data-theme="forest"]', "--space-1");
omits('[data-theme="forest"]', "--palette-gray-1");

// Dark by preference, unless data-mode says light, for the default theme
// and for each theme.
declares(
  `${DARK} / :root:not([data-mode="light"])`,
  "--palette-gray-1",
  GRAY1_DARK,
);
declares(
  `${DARK} / :root:not([data-mode="light"])`,
  "--color-surface",
  "var(--role-neutral-1)",
);
for (const theme of ["ocean", "forest"]) {
  const key = `${DARK} / [data-theme="${theme}"]:not([data-mode="light"])`;
  declares(key, "--palette-gray-1", GRAY1_DARK);
  declares(
    key,
    "--role-neutral-1",
    `var(--palette-${theme === "ocean" ? "gray" : "sand"}-1)`,
  );
  omits(key, "--space-1");
}

// Dark by data-mode, and light forced by data-mode, with and without a
// theme on the same element.
declares('[data-mode="dark"]', "--palette-gray-1", GRAY1_DARK);
declares('[data-mode="light"]', "--palette-gray-1", GRAY1_LIGHT);
for (const theme of ["ocean", "forest"]) {
  declares(
    `[data-theme="${theme}"][data-mode="dark"]`,
    "--palette-gray-1",
    GRAY1_DARK,
  );
  declares(
    `[data-theme="${theme}"][data-mode="light"]`,
    "--palette-gray-1",
    GRAY1_LIGHT,
  );
}

// Radix's blue 9 is the same in both modes, so no mode block declares it.
omits('[data-mode="dark"]', "--palette-blue-9");

// The order the cascade depends on: defaults, themes, preference, then
// data-mode, which must come after the preference to override it.
const order = [
  ":root",
  '[data-theme="forest"]',
  `${DARK} / [data-theme="forest"]:not([data-mode="light"])`,
  '[data-mode="light"]',
  '[data-theme="forest"][data-mode="dark"]',
];
const keys = [...blocks.keys()];
for (let i = 1; i < order.length; i += 1) {
  expect(
    keys.indexOf(order[i - 1]) < keys.indexOf(order[i]),
    `${order[i - 1]} must come before ${order[i]}`,
  );
}

// tomato is in the palette layer, but no theme refers to it.
expect(
  !css.includes("--palette-tomato"),
  "tomato is emitted, though no token refers to it",
);
expect(
  css.includes("--palette-sand-12"),
  "sand, which forest refers to, is missing",
);

if (failures.length > 0) {
  console.error(`css_test:\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
console.log(`css_test: ${blocks.size} blocks as expected`);
