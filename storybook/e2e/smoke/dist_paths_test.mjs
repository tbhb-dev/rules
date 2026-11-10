// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Inspect every byte of every file, including chunks the browser hasn't loaded.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const fragments = {
  ".vite/": /\.vite\//g,
  "test temp dir": process.env.TEST_TMPDIR,
  "build temp dir": /\/storybook-[A-Za-z0-9]{6}(?=[/"\\])/g,
  "/tmp/storybook-": /\/tmp\/storybook-/g,
  "/tmp/": /\/tmp\//g,
  execroot: /execroot/g,
  "bazel-out": /bazel-out/g,
  "/home/": /\/home\//g,
  "/Users/": /\/Users\//g,
  "/private/var/": /\/private\/var\//g,
  // user-event implements the browser's fixed fakepath placeholder; it is
  // never a build-machine path. Exclude only that exact directory below.
  "drive path": /(?<![\w$\\])[A-Za-z]:[\\/]+(?![\\/])(?=[\w.-])/g,
};
let failed = false;
for (const dist of process.argv.slice(2)) {
  const counts = Object.fromEntries(Object.keys(fragments).map((key) => [key, 0]));
  let files = 0;
  function walk(dir, prefix = "") {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      const entry = `${prefix}${name}`;
      if (statSync(path).isDirectory()) {
        walk(path, `${entry}/`);
        continue;
      }
      files += 1;
      const content = readFileSync(path)
        .toString("latin1")
        .replace(/C:\\+fakepath\\+/g, "");
      for (const [label, fragment] of Object.entries(fragments)) {
        const text = fragment instanceof RegExp ? `${entry}\n${content}` : content;
        const matches =
          fragment instanceof RegExp
            ? [...text.matchAll(fragment)]
            : fragment
              ? [
                  ...text.matchAll(
                    new RegExp(fragment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"),
                  ),
                ]
              : [];
        counts[label] += matches.length;
        if (matches.length > 0) {
          console.error(
            `dist_paths_test: ${dist}/${entry}: ${label}: ${matches.length}`,
          );
          for (const match of matches) {
            const context = text.slice(
              Math.max(0, match.index - 60),
              match.index + match[0].length + 60,
            );
            console.error(
              `dist_paths_test: ${dist}/${entry}: ${label}: ${JSON.stringify(context)}`,
            );
          }
          failed = true;
        }
      }
    }
  }
  walk(dist);
  console.log(`dist_paths_test: ${dist}: ${files} files: ${JSON.stringify(counts)}`);
}
process.exitCode = Number(failed);
