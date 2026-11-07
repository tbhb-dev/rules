// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// radix_palettes writes each scale's solid steps 1 to 12, opaque, and its
// alpha steps a1 to a12 with a six-digit hex. Radix makes some of the last
// alpha steps opaque (blueDarkA12), so an alpha step's alpha is at most 1,
// and the first is translucent.

import { readFileSync } from "node:fs";
import { join } from "node:path";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const failures = [];
for (const rel of process.env.TBHB_PALETTES.split(" ")) {
  const [scale, group] = Object.entries(
    JSON.parse(readFileSync(join(runfiles, rel), "utf8")).palette,
  )[0];
  for (let step = 1; step <= 12; step += 1) {
    const solid = group[step]?.$value;
    const alpha = group[`a${step}`]?.$value;
    if (!solid || "alpha" in solid) {
      failures.push(`${rel}: palette.${scale}.${step} is missing or translucent`);
    }
    const a = alpha?.alpha ?? 1;
    if (!alpha || !(a > 0 && a <= 1) || (step === 1 && a === 1)) {
      failures.push(`${rel}: palette.${scale}.a${step} has alpha ${a}`);
    }
    if (alpha && !/^#[0-9a-f]{6}$/.test(alpha.hex)) {
      failures.push(`${rel}: palette.${scale}.a${step} hex ${alpha.hex} isn't six digits`);
    }
  }
}
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
