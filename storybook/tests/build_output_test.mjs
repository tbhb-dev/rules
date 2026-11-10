// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "vitest";
import { astroBuild } from "../build_output.mjs";
import { tbhbVite } from "../vite_layer.mjs";

test("only Astro gets the build-only plugin, after the framework", () => {
  const options = { roots: ["/project"], stores: [] };
  const existing = { name: "framework" };
  for (const framework of ["astro", "react", "web-components", "html"]) {
    const config = tbhbVite({ plugins: [existing] }, { ...options, framework });
    assert.equal(config.plugins[1], existing);
    assert.equal(config.plugins.length, framework === "astro" ? 3 : 2);
  }
  const plugin = astroBuild("/project");
  assert.equal(plugin.name, "tbhb-storybook-astro-build");
  assert.equal(plugin.apply, "build");
  assert.equal(plugin.enforce, "post");
  assert.equal(plugin.transformIndexHtml.order, "post");
});

test("client markers use project-relative ids without touching other code", () => {
  const plugin = astroBuild("/project");
  assert.equal(plugin.transform("untouched", "/project/story.ts"), null);
  assert.deepEqual(plugin.transform("untouched", "/project/Other.astro"), {
    code: "untouched",
    map: null,
  });
  const unrelated = 'const source = "/project/Other.astro";';
  assert.equal(
    plugin.transform(unrelated, "/project/Other.astro").code,
    unrelated,
  );
  const id = "/project/src/Greeting.astro";
  const marker = `__astro_component.moduleId = ${JSON.stringify(id)};`;
  assert.deepEqual(plugin.transform(`before;${marker}after;`, id), {
    code: 'before;__astro_component.moduleId = "./src/Greeting.astro";after;',
    map: null,
  });
});

test("only the emitted resolveFrom option is removed", () => {
  const { handler } = astroBuild("/project").transformIndexHtml;
  assert.equal(handler("untouched"), "untouched");
  const options = {
    resolveFrom: "/project",
    renderMode: "static",
    docgen: false,
  };
  assert.equal(
    handler(
      `before;window.FRAMEWORK_OPTIONS = ${JSON.stringify(options)};after;`,
    ),
    'before;window.FRAMEWORK_OPTIONS = {"renderMode":"static","docgen":false};after;',
  );
});

test("prerender annotations are portable; other content stays byte-identical", () => {
  const outDir = mkdtempSync(join(tmpdir(), "storybook-output-"));
  try {
    const plugin = astroBuild("/project");
    plugin.configResolved({ build: { outDir } });
    plugin.closeBundle(); // Non-static builds have no prerender file.
    const path = join(outDir, "astro-prerendered-stories.json");
    writeFileSync(
      path,
      JSON.stringify({
        story:
          '<h1 data-astro-source-file="/project/src/Greeting.astro">Hello</h1>',
        plain: "unchanged",
      }),
    );
    const other = join(outDir, "other.bin");
    const bytes = Buffer.from([0, 255, 42]);
    writeFileSync(other, bytes);
    plugin.closeBundle();
    assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), {
      story: '<h1 data-astro-source-file="/src/Greeting.astro">Hello</h1>',
      plain: "unchanged",
    });
    assert.deepEqual(readFileSync(other), bytes);
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
});
