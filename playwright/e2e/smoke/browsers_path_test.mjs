// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// browsersPath over planted runfiles layouts: the real directory behind a
// tree of links, and the layouts it refuses: a missing tree, an empty one,
// and a link whose target doesn't end in the link's own path.

import { mkdirSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const runfiles = process.env.RUNFILES_DIR ?? process.env.TEST_SRCDIR;
const { browsersPath } = await import(
	pathToFileURL(join(runfiles, process.env.TBHB_PLAYWRIGHT_HELPER)).href
);

const tmp = realpathSync(process.env.TEST_TMPDIR);
const failures = [];

// A runfiles root whose `_main/browsers` holds `files`, each a link to the
// same path under `real/`, or to `real/<target>` when one is given.
function layout(name, files) {
	const root = join(tmp, name, "runfiles");
	const real = join(tmp, name, "real");
	for (const [file, target = file] of files) {
		const dest = join(real, target);
		mkdirSync(join(dest, ".."), { recursive: true });
		writeFileSync(dest, "");
		const link = join(root, "_main", "browsers", file);
		mkdirSync(join(link, ".."), { recursive: true });
		symlinkSync(dest, link);
	}
	mkdirSync(root, { recursive: true });
	writeFileSync(join(tmp, name, "path.txt"), "_main/browsers\n");
	process.env.RUNFILES_DIR = root;
	return { real, pathFile: join("..", "path.txt") };
}

function expectError(label, pathFile, message) {
	try {
		browsersPath(pathFile);
		failures.push(`${label}: no error`);
	} catch (error) {
		if (!error.message.includes(message)) {
			failures.push(`${label}: ${error.message}`);
		}
	}
}

const ok = layout("ok", [["chromium-1/chrome-mac/Chromium"]]);
const found = browsersPath(ok.pathFile);
if (found !== ok.real) {
	failures.push(`ok: ${found}, not ${ok.real}`);
}

const missing = layout("missing", []);
expectError("missing", missing.pathFile, "the pinned browsers aren't at");

const empty = layout("empty", []);
mkdirSync(join(tmp, "empty", "runfiles", "_main", "browsers"), {
	recursive: true,
});
expectError("empty", empty.pathFile, "hold no files");

const odd = layout("odd", [["chromium-1/marker", "elsewhere/other"]]);
expectError(
	"odd",
	odd.pathFile,
	"so the browsers' real directory can't be derived",
);

if (failures.length > 0) {
	console.error(`browsers_path_test:\n  ${failures.join("\n  ")}`);
	process.exit(1);
}
console.log("browsers_path_test: the real directory, and each refusal");
