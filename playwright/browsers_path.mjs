// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// browsersPath(pathFile): the pinned browsers' real directory, for
// PLAYWRIGHT_BROWSERS_PATH. pathFile is the location, relative to the
// runfiles root, of @tbhb_rules_playwright//:chromium's output, as
// `$(rlocationpath @tbhb_rules_playwright//:chromium)` gives it.
//
// The runfiles tree links each file, not each directory, so the browsers'
// real directory comes from one file's real path. Under it the browser's
// path is far shorter: on Windows the runfiles path to the executable runs
// past MAX_PATH, and CreateProcess then fails with ENOENT although the file
// is there.

import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { join, relative } from "node:path";

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

export function browsersPath(pathFile) {
  const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
  const linked = join(
    runfiles,
    readFileSync(join(runfiles, pathFile), "utf8").trim(),
  );
  if (!existsSync(linked)) {
    // On Windows without --enable_runfiles there is no runfiles tree to
    // find the browsers in.
    throw new Error(
      `the pinned browsers aren't at ${linked}; on Windows, build with --enable_runfiles`,
    );
  }
  const sample = firstFile(linked);
  const real = realpathSync(sample);
  const rel = relative(linked, sample);
  if (!real.endsWith(rel)) {
    // Falling back to the runfiles path would bring back the opaque Windows
    // ENOENT, so a layout surprise fails here as itself.
    throw new Error(
      `the real path ${real} of ${sample} doesn't end in ${rel}, so the browsers' real directory can't be derived`,
    );
  }
  return real.slice(0, real.length - rel.length - 1);
}
