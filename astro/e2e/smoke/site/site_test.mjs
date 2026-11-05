// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The built site's index.html must hold the page's rendered heading.
import { readFileSync } from "node:fs";
import { join } from "node:path";

const html = readFileSync(join(process.argv[2], "index.html"), "utf8");
if (!html.includes("<h1>Hello from tbhb_rules_astro</h1>")) {
  console.error(`site_test: index.html lacks the heading:\n${html}`);
  process.exit(1);
}
console.log("site_test: index.html holds the heading");
