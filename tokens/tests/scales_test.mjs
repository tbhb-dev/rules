// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// radix_palettes checks scale names against RADIX_SCALES when loaded; the
// tool generates from the pinned @radix-ui/colors. The two must agree.

import { execFileSync } from "node:child_process";
import { join } from "node:path";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const tool = join(runfiles, process.env.TBHB_TOKENS_TOOL);
const actual = execFileSync(tool, ["scales"], {
  encoding: "utf8",
  env: { ...process.env, BAZEL_BINDIR: "." },
})
  .trim()
  .split("\n");
const listed = process.env.TBHB_RADIX_SCALES.split(" ");
const missing = actual.filter((s) => !listed.includes(s));
const extra = listed.filter((s) => !actual.includes(s));
if (missing.length > 0 || extra.length > 0) {
  console.error(
    `scales_test: RADIX_SCALES in private/radix.bzl disagrees with the pinned @radix-ui/colors: add ${missing.join(", ") || "nothing"}, remove ${extra.join(", ") || "nothing"}`,
  );
  process.exit(1);
}
console.log(`scales_test: ${listed.length} scales match @radix-ui/colors`);
